-- auto_intel_vsr.lua (Echostorm Edition for Intel Arc)
-- Applies Intel VSR (d3d11vpp) upscaling when the video resolution is below
-- the display resolution.
-- 3-second delay is intentional: gives hwdec time to settle after file load.
--
-- 本地修订：
-- - 放入 scripts/ 目录由 mpv 自动加载
-- - 新增对 display-width/height 的监听：窗口跨显示器移动后自动重新评估
-- - 滤镜插入失败时不再误报成功；OSD 仅在实际倍率变化时弹出，避免反复刷屏
-- - vf 链被外部清空（配置组 restore、手动 vf clr 等）后自动挂回
-- 分辨率门槛逻辑：视频分辨率 >= 显示器分辨率（scale<=1）时一律不启用

local pending_timer   = nil
local applying        = false  -- guard against re-entrant trigger from vf changes
local vsr_was_applied = false  -- tracks whether VSR is currently in the chain
local last_scale      = nil    -- last successfully applied scale, for OSD de-dup

local function apply_vsr()
    applying = true

    local display_width  = mp.get_property_native("display-width")
    local display_height = mp.get_property_native("display-height")
    local video_width    = mp.get_property_native("width")
    local video_height   = mp.get_property_native("height")

    -- Remove existing VSR filter if present
    local vf_current = mp.get_property("vf") or ""
    if vf_current:find("@vsr", 1, true) then
        mp.commandv("vf", "remove", "@vsr")
    end

    vsr_was_applied = false  -- reset; will be set true below if we apply

    if video_width and video_height and display_width and display_height then
        local scale = math.max(display_width, display_height)
                    / math.max(video_width, video_height)
        scale = math.floor(scale * 10) / 10  -- round down to nearest 0.1

        if scale > 1 then
            -- Intel VSR supports more pixel formats including 10-bit (HDR P010)
            local ok = mp.commandv("vf", "append",
                "@vsr:d3d11vpp:scaling-mode=intel:scale=" .. scale)
            if ok then
                vsr_was_applied = true
                if last_scale ~= scale then
                    mp.osd_message("Intel VSR: " .. scale .. "x upscale", 2)
                end
                last_scale = scale
            else
                mp.msg.warn("Intel VSR: d3d11vpp insert failed. "
                    .. "Check Intel driver / Arc Control VSR switch and d3d11 hwdec.")
                last_scale = nil
            end
        else
            -- source resolution >= display resolution: no upscaling needed
            last_scale = nil
        end
    end

    applying = false
end

local function schedule_vsr()
    -- Don't re-trigger if we're in the middle of applying (vf change from ourselves)
    if applying then return end

    -- Cancel any pending timer so rapid changes don't stack
    if pending_timer then
        pending_timer:kill()
        pending_timer = nil
    end

    pending_timer = mp.add_timeout(3, function()
        pending_timer = nil
        apply_vsr()
    end)
end

-- Trigger on format change (file load, track switch)
mp.observe_property("video-params/pixelformat",    "native", schedule_vsr)
mp.observe_property("video-params/hw-pixelformat", "native", schedule_vsr)

-- Re-evaluate when the window moves to a different monitor
mp.observe_property("display-width",  "native", schedule_vsr)
mp.observe_property("display-height", "native", schedule_vsr)

-- Re-apply if vf chain is externally cleared (e.g. user runs 'vf clr',
-- conditional profile restore) but NOT when we're the ones changing it,
-- and NOT on videos where VSR was never applied (avoids spurious reschedules
-- on deband toggle etc.)
mp.observe_property("vf", "native", function()
    if applying then return end
    local vf_now = mp.get_property("vf") or ""
    if vsr_was_applied and not vf_now:find("@vsr", 1, true) then
        schedule_vsr()
    end
end)
