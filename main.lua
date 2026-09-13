-- LuatOS Air780EHM
-- 功能：USB VUART_0 + JSON命令管理 + SMS收发/暂存
-- 适用：Air780EHM 64位 101号固件
-- 通信约定：每条JSON后追加\n作为一帧

PROJECT = "Air780EHM_SMS_VUART"
VERSION = "1.1.0"

sys = require("sys")

local VUART = uart.VUART_0
local SMS_MAX = 1000
local RX_MAX = 4096
local SMS_NEW_PERIOD = 5000

----------------------------------------------------------------
-- USB虚拟串口
----------------------------------------------------------------
local uart_rx_cache = ""

local function uart_send(obj)
    local data, err = json.encode(obj)
    if not data then
        log.error("UART", "JSON编码失败", err)
        return false
    end

    -- 换行作为JSON帧结束符
    uart.write(VUART, data .. "\n")
    return true
end

local function uart_send_error(code, message, cmd)
    uart_send({
        event = "ERROR",
        success = false,
        code = code,
        message = message,
        cmd = cmd
    })
end

----------------------------------------------------------------
-- SMS暂存队列
-- sms_slots[id] = {
--     id       = 0~999,
--     phone    = string,
--     text     = string,
--     metas    = table/nil,
--     fetched  = false,
--     seq      = 递增序号
-- }
----------------------------------------------------------------
local sms_slots = {}
local sms_next_id = 0
local sms_seq = 0

local function sms_queue_count()
    local n = 0
    for _ in pairs(sms_slots) do
        n = n + 1
    end
    return n
end

local function sms_find_oldest()
    local oldest = nil
    for _, item in pairs(sms_slots) do
        if oldest == nil or item.seq < oldest.seq then
            oldest = item
        end
    end
    return oldest
end

local function sms_has_unfetched()
    for _, item in pairs(sms_slots) do
        if not item.fetched then
            return true
        end
    end
    return false
end

-- 只要短信还存在于暂存队列中，就认为尚未完成确认。
-- SMS_GET 只会把 fetched 置为 true，不会删除短信；
-- 因此即使 PC 已经执行 SMS_GET，但还没有 SMS_OK，仍然必须继续发送 SMS_NEW。
local function sms_has_pending()
    return next(sms_slots) ~= nil
end

-- 分配0~999循环ID。
-- ID只有在原消息从暂存数组删除后才允许再次使用。
local function sms_alloc_id()
    if sms_queue_count() >= SMS_MAX then
        return nil
    end

    for i = 0, SMS_MAX - 1 do
        local id = sms_next_id
        sms_next_id = (sms_next_id + 1) % SMS_MAX

        if sms_slots[id] == nil then
            return id
        end
    end

    return nil
end

local function sms_store(phone, text, metas)
    if not phone or not text then
        log.warn("SMS", "收到无效短信")
        return nil, "INVALID_SMS"
    end

    if #text > 1600 then
        log.warn("SMS", "短信内容过长", #text)
        return nil, "SMS_TOO_LONG"
    end

    local id = sms_alloc_id()
    if id == nil then
        log.error("SMS", "短信暂存队列已满")
        return nil, "SMS_QUEUE_FULL"
    end

    sms_seq = sms_seq + 1

    sms_slots[id] = {
        id = id,
        phone = phone,
        text = text,
        metas = metas,
        fetched = false,
        seq = sms_seq
    }

    log.info("SMS", "短信进入暂存队列", "id", id, "phone", phone)
    return id, nil
end

local function sms_delete(id)
    if sms_slots[id] == nil then
        return false
    end

    sms_slots[id] = nil
    log.info("SMS", "删除暂存短信", "id", id)
    return true
end

----------------------------------------------------------------
-- SMS接收
----------------------------------------------------------------
local function sms_callback(phone, text, metas)
    local id, err = sms_store(phone, text, metas)
    if not id then
        uart_send({
            event = "SMS_STORE_RESULT",
            success = false,
            code = err
        })
        return
    end

    uart_send({
        event = "SMS_STORED",
        success = true,
        id = id
    })
end

----------------------------------------------------------------
-- SMS发送
-- 使用sms.sendLong().wait()：同步获取最终结果，同时支持中文/长短信。
----------------------------------------------------------------
local sms_send_busy = false

local function sms_send_task(cmd)
    if sms_send_busy then
        uart_send_error("SMS_SEND_BUSY", "已有短信正在发送", cmd.cmd)
        return
    end

    sms_send_busy = true

    local phone = cmd.phone
    local text = cmd.text

    -- 基本参数检查
    if type(phone) ~= "string" or phone == "" then
        uart_send_error("INVALID_PHONE", "手机号不能为空", "SMS_SEND")
        sms_send_busy = false
        return
    end

    if type(text) ~= "string" or text == "" then
        uart_send_error("INVALID_TEXT", "短信内容不能为空", "SMS_SEND")
        sms_send_busy = false
        return
    end

    log.info("SMS", "开始发送短信", phone, text)

    local ok = false
    local success_call, result = pcall(function()
        return sms.sendLong(phone, text, true).wait()
    end)

    if success_call then
        ok = (result == true)
    else
        log.error("SMS", "sms.sendLong异常", result)
    end

    uart_send({
        event = "SMS_SEND_RESULT",
        success = ok,
        phone = phone,
        message = ok and "短信发送成功" or "短信发送失败"
    })

    sms_send_busy = false
end

----------------------------------------------------------------
-- 命令处理器
-- 后续增加命令：只需要增加command_handlers[命令名]即可。
----------------------------------------------------------------
local command_handlers = {}

command_handlers["SMS_GET"] = function(cmd)
    local item = sms_find_oldest()

    if not item then
        uart_send({
            event = "SMS_GET_RESULT",
            success = true,
            found = false,
            message = "当前没有暂存短信"
        })
        return
    end

    -- 只要被PC取过，就标记为fetched。
    -- 在收到SMS_OK前不会删除，因此PC重复执行SMS_GET时仍可重新获取最早一条。
    item.fetched = true

    local out = {
        event = "SMS_GET_RESULT",
        success = true,
        found = true,
        id = item.id,
        phone = item.phone,
        text = item.text
    }

    if item.metas then
        out.metas = item.metas
    end

    uart_send(out)
end

command_handlers["SMS_OK"] = function(cmd)
    local id = cmd.id

    if type(id) ~= "number" then
        uart_send_error("INVALID_ID", "SMS_OK需要数字类型id", "SMS_OK")
        return
    end

    -- 只允许删除已经成功提取过的短信。
    local item = sms_slots[id]
    if item == nil then
        uart_send({
            event = "SMS_OK_RESULT",
            success = false,
            id = id,
            message = "短信ID不存在"
        })
        return
    end

    if not item.fetched then
        uart_send({
            event = "SMS_OK_RESULT",
            success = false,
            id = id,
            message = "该短信尚未执行SMS_GET，拒绝删除"
        })
        return
    end

    local ok = sms_delete(id)

    uart_send({
        event = "SMS_OK_RESULT",
        success = ok,
        id = id,
        message = ok and "短信已确认并删除" or "短信删除失败"
    })
end

command_handlers["SMS_TEST"] = function(cmd)
    -- 模拟收到短信时，在内容尾部附加当前开发板系统时间。
    -- 这样每次执行SMS_TEST生成的短信内容都可以通过时间区分。
    local text = "这是一条模拟收到的短信，用于PC和开发板通信测试。 时间：" .. os.date("%Y-%m-%d %H:%M:%S")

    local id, err = sms_store("13800138000", text, nil)

    if not id then
        uart_send({
            event = "SMS_TEST_RESULT",
            success = false,
            code = err
        })
        return
    end

    uart_send({
        event = "SMS_TEST_RESULT",
        success = true,
        id = id,
        phone = "13800138000",
        text = text
    })
end

command_handlers["SMS_SEND"] = function(cmd)
    -- 放到独立task，避免阻塞VUART接收回调
    sys.taskInit(sms_send_task, cmd)
end

-- SYS_TIME默认时区：东八区。
-- PC端使用便于理解的整点时区表示，例如：+8、-4。
-- LuatOS rtc.timezone() 使用“1/4时区”为单位，因此：
-- +8  -> 32
-- -4  -> -16
local SYS_TIME_DEFAULT_TZ = 8

-- 将PC传入的整点时区转换成LuatOS rtc.timezone()需要的1/4时区值。
-- 例如 +8 -> 32，-4 -> -16。
local function timezone_to_rtc(tz)
    if tz == nil then
        tz = SYS_TIME_DEFAULT_TZ
    end

    if type(tz) ~= "number" then
        return nil, "INVALID_TIMEZONE"
    end

    -- 本接口约定PC传入整数整点时区，例如+8、0、-4。
    -- 不接受半小时/45分钟时区，避免协议含义不明确。
    if tz ~= math.floor(tz) or tz < -12 or tz > 12 then
        return nil, "INVALID_TIMEZONE"
    end

    return tz * 4
end

local function sys_time_handler(cmd)
    -- 不带rtc参数：PC请求当前开发板本地时间。
    if cmd.rtc == nil then
        uart_send({
            event = "SYS_TIME_RESULT",
            success = true,
            time = os.date("%Y-%m-%d %H:%M:%S"),
            timezone = (rtc.timezone()) / 4
        })
        return
    end

    -- rtc必须使用number类型Unix时间戳。
    if type(cmd.rtc) ~= "number" or cmd.rtc ~= math.floor(cmd.rtc) then
        uart_send_error("INVALID_RTC", "rtc必须是number类型的Unix时间戳", "SYS_TIME")
        return
    end

    local rtc_tz, tz_err = timezone_to_rtc(cmd.timezone)
    if not rtc_tz then
        uart_send_error(tz_err, "timezone必须是-12到12之间的整数，例如+8、-4", "SYS_TIME")
        return
    end

    -- LuatOS官方说明：rtc.set()设置的是UTC时间；
    -- rtc.timezone()负责设置本地时区。因此先设置UTC时间，再设置时区。
    local ok_set = rtc.set(cmd.rtc)
    if not ok_set then
        uart_send({
            event = "SYS_TIME_RESULT",
            success = false,
            message = "RTC时间设置失败"
        })
        return
    end

    local actual_tz = rtc.timezone(rtc_tz)
    local tz_ok = (actual_tz == rtc_tz)
    if not tz_ok then
        uart_send({
            event = "SYS_TIME_RESULT",
            success = false,
            message = "时区设置失败"
        })
        return
    end

    uart_send({
        event = "SYS_TIME_RESULT",
        success = true,
        time = os.date("%Y-%m-%d %H:%M:%S"),
        rtc = cmd.rtc,
        timezone = rtc_tz / 4
    })
end

-- 注册SYS_TIME命令处理器。
-- 注意：SYS_TIME函数虽然已经定义，但如果没有加入command_handlers，
-- PC发送 {"cmd":"SYS_TIME"} 时dispatch_command()仍会认为是未知命令。
command_handlers["SYS_TIME"] = sys_time_handler


----------------------------------------------------------------
-- 电话功能
--
-- 这里只处理电话控制，不接听、不进行语音通话。
-- 官方CC模块通过 CC_IND 系统消息报告来电、接通、断开等状态。
--
-- INCOMINGCALL     ：有来电呼入
-- MAKE_CALL_OK    ：拨号请求成功，正在等待对方接听
-- PLAY            ：对方开始响铃（开始有音频输出）
-- CONNECTED       ：电话已接通
-- DISCONNECTED    ：通话断开
-- MAKE_CALL_FAILED：拨号失败
-- HANGUP_CALL_DONE：挂断请求完成
--
-- 计时规则：
-- 1、呼入：收到INCOMINGCALL时开始计时，因为这时已经检测到来电。
-- 2、呼出：收到PLAY时才开始计时。
--    PLAY表示开始有音频输出，即对方已经进入响铃阶段；
--    因此不能在PC执行dial时开始计算10秒。
-- 3、呼出收到PLAY后，10秒自动挂断。
-- 4、如果对方在10秒内接听，收到CONNECTED后立即挂断。
----------------------------------------------------------------
local CALL_SIM_ID = 0
local CALL_AUTO_HANGUP_MS = 10000

local call_active = false
local call_type = nil             -- "incoming" / "outgoing"
local call_phone = ""
local call_start_time = 0         -- 真正开始计时时间
local call_hangup_reported = false

local function call_duration()
    if call_start_time <= 0 then
        return 0
    end

    local duration = os.time() - call_start_time
    if duration < 0 then
        duration = 0
    end
    return duration
end

local function call_reset()
    call_active = false
    call_type = nil
    call_phone = ""
    call_start_time = 0
    call_hangup_reported = false
end

local function call_auto_hangup()
    -- 只有呼出电话进入PLAY后才启动这个10秒定时器。
    if not call_active or call_type ~= "outgoing" then
        return
    end

    if call_start_time <= 0 then
        return
    end

    log.info("CALL", "PLAY后10秒，自动挂断", call_phone)
    cc.hangUp(CALL_SIM_ID)
end

local function call_report_hangup()
    if not call_active then
        return
    end

    -- CC可能同时产生HANGUP_CALL_DONE和DISCONNECTED，确保PC只收到一次hangUp。
    if call_hangup_reported then
        return
    end

    call_hangup_reported = true
    local phone = call_phone
    local duration = call_duration()

    uart_send({
        event = "hangUp",
        phone = phone,
        duration = duration
    })

    log.info("CALL", "电话挂断", phone, "duration", duration)

    -- 停止10秒自动挂断定时器。
    sys.timerStop(call_auto_hangup)
    call_reset()
end

local function call_status_callback(status)
    log.info("CALL", "CC状态", status)

    if status == "INCOMINGCALL" then
        -- 只记录来电号码，不自动接听。
        if call_active then
            log.warn("CALL", "已有电话正在处理中，忽略新的INCOMINGCALL")
            return
        end

        local phone = cc.lastNum()
        if not phone or phone == "" then
            phone = "未知号码"
        end

        call_active = true
        call_type = "incoming"
        call_phone = phone
        call_start_time = os.time()
        call_hangup_reported = false

        uart_send({
            event = "INCOMINGCALL",
            phone = call_phone
        })

        log.info("CALL", "来电", call_phone)

    elseif status == "PLAY" then
        -- 对于呼出电话，PLAY表示开始有音频输出，即对方手机开始响铃。
        -- 按需求，从这个时刻开始计算10秒自动挂断时间及呼叫时长。
        if call_active and call_type == "outgoing" then
            if call_start_time <= 0 then
                call_start_time = os.time()

                log.info("CALL", "对方开始响铃，开始计时", call_phone)

                -- 定时器也从PLAY这个时刻开始，而不是从dial命令开始。
                sys.timerStart(call_auto_hangup, CALL_AUTO_HANGUP_MS)
            end
        end

    elseif status == "CONNECTED" then
        -- 呼出电话被对方接听后，立即挂断，不进行实际通话。
        if call_active and call_type == "outgoing" then
            log.info("CALL", "对方已接听，立即挂断", call_phone)
            cc.hangUp(CALL_SIM_ID)
        end

    elseif status == "MAKE_CALL_FAILED" then
        -- 拨号失败不伪造hangUp，直接通知PC拨号失败。
        if call_active and call_type == "outgoing" then
            sys.timerStop(call_auto_hangup)
            uart_send({
                event = "dial",
                success = false,
                phone = call_phone
            })
            call_reset()
        end

    elseif status == "DISCONNECTED" or status == "HANGUP_CALL_DONE" then
        call_report_hangup()
    end
end

-- CC_IND是官方CC模块提供的通话状态系统消息。
-- 官方要求在cc.init()之前订阅CC_IND，因此这里放在初始化之前。
sys.subscribe("CC_IND", call_status_callback)

-- 初始化电话控制功能。
-- 官方API：cc.init(multimedia_id)，Air780EHM通常使用多媒体通道0。
-- 本项目不启用录音、不初始化音频播放，只使用呼叫控制状态。
sys.taskInit(function()
    local init_ok = false
    local success_call, result = pcall(function()
        return cc.init(CALL_SIM_ID)
    end)

    if success_call then
        init_ok = (result == true)
    else
        log.error("CALL", "cc.init异常", result)
    end

    log.info("CALL", "电话功能初始化", init_ok)
end)

command_handlers["dial"] = function(cmd)
    if call_active then
        uart_send_error("CALL_BUSY", "当前已有电话正在处理", "dial")
        return
    end

    if type(cmd.phone) ~= "string" or cmd.phone == "" then
        uart_send_error("INVALID_PHONE", "dial需要phone参数", "dial")
        return
    end

    call_active = true
    call_type = "outgoing"
    call_phone = cmd.phone

    -- 注意：这里故意不开始计时。
    -- 按CC_IND状态定义，需要等PLAY（对方开始响铃）后再设置call_start_time。
    call_start_time = 0
    call_hangup_reported = false

    local dial_ok = false
    local success_call, result = pcall(function()
        return cc.dial(CALL_SIM_ID, call_phone)
    end)

    if success_call then
        dial_ok = (result == true)
    else
        log.error("CALL", "cc.dial异常", result)
    end

    if not dial_ok then
        call_reset()
        uart_send({
            event = "dial",
            success = false,
            phone = cmd.phone
        })
        return
    end

    uart_send({
        event = "dial",
        success = true,
        phone = cmd.phone
    })

    -- 不在这里启动10秒定时器。
    -- 等收到CC_IND == "PLAY"后，再从PLAY时刻开始10秒倒计时。
end

-- 安全调用接口：某些旧固件可能不存在某个API时，不影响SYS_INFO整体返回
local function safe_call(fn)
    local ok, a, b, c = pcall(fn)
    if ok then
        return a, b, c
    end
    return nil, nil, nil
end

local function get_sys_info()
    local info = {
        project = PROJECT,
        version = VERSION,
        interface = "VUART_0",
        protocol = "JSON_LINE",
        hardware = {},
        firmware = {},
        identity = {},
        sim = {},
        network = {},
        cell = {},
        memory = {},
        sms = {}
    }

    ------------------------------------------------------------
    -- 硬件信息
    -- hmeta 文档提供：model / hwver / chip / muid / devid
    ------------------------------------------------------------
    info.hardware.model = safe_call(function() return hmeta.model() end)
    info.hardware.hwver = safe_call(function() return hmeta.hwver() end)
    info.hardware.chip = safe_call(function() return hmeta.chip() end)
    info.hardware.muid = safe_call(function() return hmeta.muid() end)
    info.hardware.devid = safe_call(function() return hmeta.devid() end)
    info.hardware.bsp = safe_call(function() return rtos.bsp() end)

    ------------------------------------------------------------
    -- 固件 / RTOS 信息
    ------------------------------------------------------------
    local fw_version, fw_version_num = safe_call(function()
        return rtos.version(true)
    end)
    info.firmware.version = fw_version
    info.firmware.version_num = fw_version_num
    info.firmware.build_date = safe_call(function() return rtos.buildDate() end)
    info.firmware.name = safe_call(function() return rtos.firmware() end)

    ------------------------------------------------------------
    -- 模组 / SIM 身份信息
    ------------------------------------------------------------
    info.identity.imei = safe_call(function() return mobile.imei() end)
    info.identity.imsi = safe_call(function() return mobile.imsi() end)
    info.identity.muid = info.hardware.muid
    info.identity.devid = info.hardware.devid
    info.sim.iccid = safe_call(function() return mobile.iccid() end)
    info.sim.number = safe_call(function() return mobile.number() end)
    info.sim.id = safe_call(function() return mobile.simid() end)
    info.sim.pin_ready = safe_call(function() return mobile.simPin() end)

    ------------------------------------------------------------
    -- 蜂窝网络状态
    ------------------------------------------------------------
    info.network.status = safe_call(function() return mobile.status() end)
    info.network.csq = safe_call(function() return mobile.csq() end)
    info.network.rssi = safe_call(function() return mobile.rssi() end)
    info.network.rsrp = safe_call(function() return mobile.rsrp() end)
    info.network.rsrq = safe_call(function() return mobile.rsrq() end)
    info.network.snr = safe_call(function() return mobile.snr() end)
    info.network.eci = safe_call(function() return mobile.eci() end)
    info.network.tac = safe_call(function() return mobile.tac() end)
    info.network.enbid = safe_call(function() return mobile.enbid() end)

    ------------------------------------------------------------
    -- 当前服务小区详细信息
    ------------------------------------------------------------
    local scell = safe_call(function() return mobile.scell() end)
    if type(scell) == "table" then
        info.cell = scell
    end

    ------------------------------------------------------------
    -- 已缓存/当前小区信息
    -- 这里只读取，不主动调用reqCellInfo()，避免SYS_INFO命令产生额外搜网操作
    ------------------------------------------------------------
    local cell_info = safe_call(function() return mobile.getCellInfo() end)
    if type(cell_info) == "table" then
        info.network.cell_info = cell_info
    end

    ------------------------------------------------------------
    -- APN配置（仅读取，不修改）
    ------------------------------------------------------------
    local apn_name, apn_user, apn_password, apn_ip_type, apn_protocol = safe_call(function()
        return mobile.apn(0, 1)
    end)
    info.network.apn = {
        name = apn_name,
        user = apn_user,
        password = apn_password,
        ip_type = apn_ip_type,
        protocol = apn_protocol
    }

    ------------------------------------------------------------
    -- 内存信息
    ------------------------------------------------------------
    local total_lua, used_lua, max_used_lua = safe_call(function()
        return rtos.meminfo("lua")
    end)
    info.memory.lua = {
        total = total_lua,
        used = used_lua,
        max_used = max_used_lua
    }

    local total_sys, used_sys, max_used_sys = safe_call(function()
        return rtos.meminfo("sys")
    end)
    info.memory.sys = {
        total = total_sys,
        used = used_sys,
        max_used = max_used_sys
    }

    local total_psram, used_psram, max_used_psram = safe_call(function()
        return rtos.meminfo("psram")
    end)
    info.memory.psram = {
        total = total_psram,
        used = used_psram,
        max_used = max_used_psram
    }

    ------------------------------------------------------------
    -- 数据流量统计
    -- 仅查询统计值，不建立数据连接
    ------------------------------------------------------------
    local up_bytes, down_bytes = safe_call(function()
        return mobile.dataTraffic()
    end)
    info.network.data_traffic = {
        uplink_bytes = up_bytes,
        downlink_bytes = down_bytes
    }

    ------------------------------------------------------------
    -- 本次开机原因（Air780系列支持）
    ------------------------------------------------------------
    local reason_a, reason_b, reason_c, reason_d = safe_call(function()
        return pm.lastReson()
    end)
    info.hardware.power_on_reason = {
        source = reason_a,
        mode = reason_b,
        reset_reason = reason_c,
        wakeup = reason_d
    }

    ------------------------------------------------------------
    -- 本程序短信队列信息
    ------------------------------------------------------------
    local oldest = sms_find_oldest()
    info.sms.count = sms_queue_count()
    info.sms.pending = sms_has_pending()
    info.sms.unfetched = sms_has_unfetched()
    info.sms.oldest_id = oldest and oldest.id or nil
    info.sms.next_id = sms_next_id

    return info
end

command_handlers["SYS_INFO"] = function(cmd)
    uart_send({
        event = "SYS_INFO_RESULT",
        success = true,
        info = get_sys_info()
    })
end

command_handlers["STATUS"] = function(cmd)
    local oldest = sms_find_oldest()

    uart_send({
        event = "STATUS_RESULT",
        success = true,
        sms_count = sms_queue_count(),
        sms_unfetched = sms_has_unfetched(),
        sms_pending = sms_has_pending(),
        sms_oldest_id = oldest and oldest.id or nil,
        sms_send_busy = sms_send_busy,
        network_status = mobile.status()
    })
end

----------------------------------------------------------------
-- JSON命令分发
----------------------------------------------------------------
local function dispatch_command(data)
    if type(data) ~= "table" then
        uart_send_error("INVALID_JSON", "JSON根节点必须是对象", nil)
        return
    end

    local cmd = data.cmd
    if type(cmd) ~= "string" or cmd == "" then
        uart_send_error("MISSING_CMD", "JSON中缺少cmd字段", nil)
        return
    end

    local handler = command_handlers[cmd]
    if not handler then
        uart_send_error("UNKNOWN_CMD", "未知命令: " .. cmd, cmd)
        return
    end

    local ok, err = pcall(handler, data)
    if not ok then
        log.error("CMD", "命令执行异常", cmd, err)
        uart_send_error("CMD_EXCEPTION", "命令执行异常", cmd)
    end
end

local function process_uart_line(line)
    line = line:gsub("^%s+", ""):gsub("%s+$", "")
    if line == "" then
        return
    end

    local obj, err = json.decode(line)
    if obj == nil then
        log.warn("UART", "JSON解析失败", err or "unknown", line)
        uart_send_error("INVALID_JSON", "JSON解析失败", nil)
        return
    end

    dispatch_command(obj)
end

----------------------------------------------------------------
-- VUART接收回调
----------------------------------------------------------------
uart.setup(
    VUART,
    115200,
    8,
    1
)

uart.on(VUART, "receive", function(id, len)
    while true do
        local data = uart.read(id, 128)
        if not data or data == "" then
            break
        end

        uart_rx_cache = uart_rx_cache .. data

        if #uart_rx_cache > RX_MAX then
            uart_rx_cache = ""
            uart_send_error("RX_OVERFLOW", "JSON命令超过最大长度", nil)
            break
        end

        while true do
            local pos = uart_rx_cache:find("\n", 1, true)
            if not pos then
                break
            end

            local line = uart_rx_cache:sub(1, pos - 1)
            uart_rx_cache = uart_rx_cache:sub(pos + 1)
            process_uart_line(line)
        end
    end
end)

----------------------------------------------------------------
-- 注册短信接收回调
----------------------------------------------------------------
sms.setNewSmsCb(sms_callback)

----------------------------------------------------------------
-- 每5秒检查是否还有未提取短信
----------------------------------------------------------------
sys.taskInit(function()
    while true do
        sys.wait(SMS_NEW_PERIOD)

        -- 只要暂存队列中还有未确认删除的短信，每5秒都提醒一次。
        -- 注意：SMS_GET 后 fetched=true，但没有 SMS_OK 时短信仍然存在，
        -- 因此这里不能再使用 sms_has_unfetched()。
        if sms_has_pending() then
            uart_send({
                event = "SMS_NEW"
            })
        end
    end
end)

----------------------------------------------------------------
-- 启动完成通知
----------------------------------------------------------------
log.info("MAIN", "Air780EHM短信/VUART程序启动")
log.info("MAIN", "USB VUART_0已初始化")
log.info("MAIN", "4G数据业务：本程序不主动建立任何IP数据连接")
log.info("MAIN", "短信功能：已注册接收回调")

uart_send({
    event = "READY",
    success = true,
    message = "设备就绪",
    project = PROJECT,
    version = VERSION,
    interface = "VUART_0",
    protocol = "JSON_LINE"
})

-- 用户代码结束---------------------------------------------
sys.run()
-- sys.run()之后后面不要加任何语句!!!!!
