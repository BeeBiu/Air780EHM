# Air780EHM
串口通信，不走流量，短信转发，来电提醒


| 工作条件 | 说明 |
| --- | --- |
| windows电脑 | 本地记录+curl转发电子邮件，配好电子邮件能收到来电提醒 |
| USB版Air780EHM硬件  | 固件建议选择64位 101号 LuatOS-SoC_V2050_Air780EHM 代码基于此版本固件开发 |
| 串口程序  | 可以直接使用本项目提供的软件，如果不想转发邮件，直接取消打勾就行，其中本地log记录是强制的无法关闭 |


- 官方固件：https://docs.openluat.com/air780epm/luatos/firmware/780ehm_version/
  - 下载后根据官方说明随本项目的 main.lua 一起刷入即可使用

- 注意合宙的虚拟串口有3个，必须选对本项目使用的虚拟串口才能正常工作

> [!WARNING]
> 开发板的短信均保存在内存里，设备断电就会丢失，因此先调试好再插卡使用，避免开发板已经开始接收短信而忘记提取
>
> 关于email的授权码，需要到POP3/SMTP服务里开启，已测试163、139、qq这些邮箱工作正常

# 网页版串口工具（仅提供基础调试功能）

> [**访问网页版**](https://beebiu.github.io/Air780EHM/)

# 串口程序可自行开发，也可以使用本项目提供的软件，仅支持转发到email

**发送和接收格式均为json，调试一下就会的，流程大概是，有新短信，会收到SMS_NEW，然后调用SMS_GET后，处理SMS_GET_RESULT消息，继续调用SMS_OK，直到SMS_NEW消息消失**

```SMS_GET``` 

获取短信  例`{"cmd":"SMS_GET"}`

```SMS_OK``` 

确认短信，释放开发板上的内存，参数id由SMS_GET返回 例```{"cmd":"SMS_OK","id":0}```

```SMS_TEST``` 

生成测试短信，模拟接收到短信的情况 例 `{"cmd":"SMS_TEST"}`

```SMS_SEND```

发送短信 例 `{"cmd":"SMS_SEND","phone":"13800138000","text":"你好，这是一条测试短信"}`

---

```SYS_TIME``` 

查询当前硬件时间 
无参数 例`{"cmd":"SYS_TIME"}`

有参是设置时间 例`{"cmd":"SYS_TIME","rtc":1710000000,"timezone":8}`

```SYS_INFO``` 

返回开发板所有信息 例`{"cmd":"SYS_INFO"}`

```STATUS```  

查询简要状态和识别设备 例`{"cmd":"STATUS"}`

---

关于电话功能，只是测试用，不具备语音通话能力，仅能知道是什么号码打进来，内部设置了10秒主动挂断


```dial``` 

主动呼出 10秒自动挂断 例`{"cmd":"dial","phone":"13800138000"}`

---

# 主动事件(接收消息)，介绍关键几个，通过判断event
例`{"phone":"13800138000","success":true,"event":"dial"}`

```SMS_NEW``` 

有新短信需要提取，只要还没有调用 SMS_GET和SMS_OK就会5秒一直循环

```SMS_GET_RESULT```

调用SMS_GET后返回短信内容和ID

```SMS_STORED``` 

短信存储状态是否成功，无需理会，除非内存爆了才会失败

```INCOMINGCALL```

有来电呼入 例`{"phone":"13800138000","event":"INCOMINGCALL"}`

```hangUp```

电话挂断

```dial``` 

呼出电话是否成功，在收到挂断消息前，不要二次发送

```error```

错误信息
