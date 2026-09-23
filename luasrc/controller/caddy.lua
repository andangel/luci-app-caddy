module("luci.controller.caddy", package.seeall)

function index()
	entry({"admin", "network", "caddy"}, alias("admin", "network", "caddy", "basic"), _("Caddy"), 30)
	entry({"admin", "network", "caddy", "basic"}, cbi("caddy/caddy"), _("状态"), 1).leaf = true
	entry({"admin", "network", "caddy", "domain"}, cbi("caddy/domain"), _("域名"), 2).leaf = true
	entry({"admin", "network", "caddy", "host"}, cbi("caddy/host"), _("主机"), 3).leaf = true
	entry({"admin", "network", "caddy", "caddyfile"}, cbi("caddy/caddyfile"), _("配置"), 4).leaf = true
	entry({"admin", "network", "caddy", "log"}, cbi("caddy/caddy_log"), _("日志"), 5).leaf = true
	entry({"admin", "network", "caddy", "caddy_status"}, call("caddy_status")).leaf = true
	entry({"admin", "network", "caddy", "get_log"}, call("get_log")).leaf = true
	entry({"admin", "network", "caddy", "clear_log"}, call("clear_log")).leaf = true
	entry({"admin", "network", "caddy", "admin_info"}, call("admin_info")).leaf = true
	entry({"admin", "network", "caddy", "download"}, call("download")).leaf = true
end

function caddy_status()
	local e={}
          local sys  = require "luci.sys"
	local uci  = require "luci.model.uci".cursor()
	-- Web 界面按钮地址: 取第一个 proxy host 的 域名:端口, 没有则留空
	local weburl = ""
	local pname = uci:get_first("caddy", "proxy")
	if pname then
		local pdom = uci:get("caddy", pname, "domain")
		local pprt = uci:get("caddy", pname, "port")
		if pdom then
			weburl = "http://" .. pdom .. (pprt and (":" .. pprt) or "")
		end
	end
	e.weburl = weburl
		    e.running=luci.sys.call("pidof caddy >/dev/null")==0
	local tagfile = io.open("/tmp/caddy_time", "r")
        if tagfile then
	local tagcontent = tagfile:read("*all")
	tagfile:close()
	if tagcontent and tagcontent ~= "" then
        os.execute("start_time=$(cat /tmp/caddy_time) && time=$(($(date +%s)-start_time)) && day=$((time/86400)) && [ $day -eq 0 ] && day='' || day=${day}天 && time=$(date -u -d @${time} +'%H小时%M分%S秒') && echo $day $time > /tmp/command_caddy 2>&1")
        local command_output_file = io.open("/tmp/command_caddy", "r")
        if command_output_file then
            e.caddysta = command_output_file:read("*all")
            command_output_file:close()
	    if e.caddysta == "" then
               e.caddysta = "unknown"
            end
        end
	end
	end

         local command2 = io.popen('test ! -z "`pidof caddy`" && (top -b -n1 | grep -E "$(pidof caddy)" 2>/dev/null | grep -v grep | awk \'{for (i=1;i<=NF;i++) {if ($i ~ /caddy/) break; else cpu=i}} END {print $cpu}\')')
                   e.caddycpu = command2:read("*all")
                   command2:close()
                   if e.caddycpu == "" then
                   e.caddycpu = "unknown"
                   end
  
         local command3 = io.popen("test ! -z `pidof caddy` && (cat /proc/$(pidof caddy | awk '{print $NF}')/status | grep -w VmRSS | awk '{printf \"%.2f MB\", $2/1024}')")
                   e.caddyram = command3:read("*all")
                   command3:close()
                   if e.caddyram == "" then
                   e.caddyram = "unknown"
                   end
  
-- 官方 CLI: caddy version (输出形如 v2.11.4 h1:xxx, 取版本号段)
         local command4 = io.popen("$(uci -q get caddy.@caddy[0].bin_dir) version 2>/dev/null | awk '{print $1}'")
                   e.caddytag = command4:read("*all")
                   command4:close()
                   if e.caddytag == "" then
                   e.caddytag = "unknown"
                   end
  
         local command5 = io.popen("([ -s /tmp/caddynew.tag ] && cat /tmp/caddynew.tag ) || ( curl -L -k -s --connect-timeout 3 --user-agent 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/117.0.0.0 Safari/537.36' https://api.github.com/repos/caddyserver/caddy/releases/latest | grep tag_name | sed 's/[^0-9.]*//g' >/tmp/caddynew.tag && cat /tmp/caddynew.tag )")
                   e.caddynewtag = command5:read("*all")
                   command5:close()
                   if e.caddynewtag == "" then
                   e.caddynewtag = "unknown"
                   end
	luci.http.prepare_content("application/json")
	luci.http.write_json(e)
end

function get_log()
	luci.http.write(luci.sys.exec("[ -s $(uci -q get caddy.@caddy[0].log_dir) ] && cat $(uci -q get caddy.@caddy[0].log_dir)"))
end

function clear_log()
	luci.sys.call("cat /dev/null > $(uci -q get caddy.@caddy[0].log_dir)")
end

function admin_info()
	-- HOME=/root 兜底: LuCI CGI (uhttpd) 环境没 $HOME/$XDG_CONFIG_HOME,
	-- caddy validate 会 warn "unable to determine directory for user configuration; falling back to current directory".
	-- 显式给个家目录就没这条 warn; --config 已显式传, 结果不受 HOME 影响.
	local validate = luci.sys.exec("env HOME=/root $(uci -q get caddy.@caddy[0].bin_dir) validate --config /etc/caddy/Caddyfile --adapter caddyfile 2>&1")
	luci.http.prepare_content("application/json")
	luci.http.write_json({ validate = validate })
end

function download()
	local uci = require "luci.model.uci".cursor()
	local r   = { ok = false, msg = "" }
	local url = uci:get("caddy", "caddy", "download_url")
	local bin = uci:get("caddy", "caddy", "bin_dir") or "/usr/sbin/caddy"

	local tmp = "/tmp/caddy.dl"
	if not url or url == "" then
		r.msg = _("请先填写 下载地址")
	else
		-- 先下到 /tmp 再 mv, 避免写一半坏掉二进制; 写完校验可执行
		local code = luci.sys.call(string.format(
			"curl -L -sfS --connect-timeout 10 --retry 2 -o %s '%s' && chmod +x %s && mv -f %s '%s'",
			tmp, url, tmp, tmp, bin))
		if code == 0 then
			if luci.sys.call(string.format("'%s' -h >/dev/null 2>&1", bin)) == 0 then
				os.execute("/etc/init.d/caddy restart >/dev/null 2>&1")
				r.ok  = true
				r.msg = _("下载完成, 已重启 Caddy")
			else
				r.msg = _("下载完成但校验失败, 可能架构不匹配")
			end
		else
			os.execute("rm -f " .. tmp)
			r.msg = _("下载失败, 检查地址与网络")
		end
	end

	luci.http.prepare_content("application/json")
	luci.http.write_json(r)
end

