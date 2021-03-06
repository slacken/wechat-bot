require "rqrcode"
require "logger"
require "uri"
require "digest"
require "json"

module WeChat::Bot
  # 微信 API 类
  class Client
    def initialize(bot)
      @bot = bot
      clone!
    end

    # 微信登录
    def login
      return @bot.logger.info("你已经登录") if logged?

      check_count = 0
      until logged?
        check_count += 1
        @bot.logger.debug "尝试登录 (#{check_count})..."

        uuid = qr_uuid
        until uuid
          @bot.logger.info "重新尝试获取登录二维码 ..."
          sleep 1
        end

        show_qr_code(uuid)

        until logged?
          status, status_data = login_status(uuid)
          case status
          when :logged
            @is_logged = true
            store_login_data(status_data["redirect_uri"])
            break
          when :scaned
            @bot.logger.info "请在手机微信确认登录 ..."
          when :timeout
            @bot.logger.info "扫描超时，重新获取登录二维码 ..."
            break
          end
        end

        break if logged?
      end

      @bot.logger.info "等待加载登录后所需资源 ..."
      login_loading
      update_notice_status

      @bot.logger.info "用户 [#{@bot.profile.nickname}] 登录成功！"
    end

    # Runloop 监听
    def start_runloop_thread
      @is_alive = true
      retry_count = 0

      Thread.new do
        while alive?
          begin
            status = sync_check
            if status[:retcode] == "0"
              if status[:selector].nil?
                @is_alive = false
              elsif status[:selector] != "0"
                sync_messages
              end
            elsif status[:retcode] == "1100"
              @bot.logger.info("账户在手机上进行登出操作")
              @is_alive = false
              break
            elsif [ "1101", "1102" ].include?(status[:retcode])
              @bot.logger.info("账户在手机上进行登出或在其他地方进行登录操作操作")
              @is_alive = false
              break
            end

            retry_count = 0
          rescue Exception => e
            retry_count += 1
            @bot.logger.fatal(e)
          end

          sleep 1
        end

        logout
      end
    end

    # 获取生成二维码的唯一识别 ID
    #
    # @return [String]
    def qr_uuid
      params = {
        "appid" => @bot.config.app_id,
        "fun" => "new",
        "lang" => "zh_CN",
        "_" => timestamp,
      }

      @bot.logger.info "获取登录唯一标识 ..."
      r = @session.get(File.join(@bot.config.auth_url, "jslogin") , params: params)
      data = r.parse(:js)

      return data["uuid"] if data["code"] == 200
    end

    # 获取二维码图片
    def show_qr_code(uuid)
      @bot.logger.info "获取登录用扫描二维码 ... "
      url = File.join(@bot.config.auth_url, "l", uuid)
      qrcode = RQRCode::QRCode.new(url)

      # image = qrcode.as_png(
      #   resize_gte_to: false,
      #   resize_exactly_to: false,
      #   fill: "white",
      #   color: "black",
      #   size: 120,
      #   border_modules: 4,
      #   module_px_size: 6,
      # )
      # IO.write(QR_FILENAME, image.to_s)

      svg = qrcode.as_ansi(
        light: "\033[47m",
        dark: "\033[40m",
        fill_character: "  ",
        quiet_zone_size: 2
      )

      puts svg
    end

    # 处理微信登录
    #
    # @return [Array]
    def login_status(uuid)
      timestamp = timestamp()
      params = {
        "loginicon" => "true",
        "uuid" => uuid,
        "tip" => 0,
        "r" => timestamp.to_i / 1579,
        "_" => timestamp,
      }

      r = @session.get(File.join(@bot.config.auth_url, "cgi-bin/mmwebwx-bin/login"), params: params)
      data = r.parse(:js)
      status = case data["code"]
               when 200 then :logged
               when 201 then :scaned
               when 408 then :waiting
               else          :timeout
               end

      [status, data]
    end

    # 保存登录返回的数据信息
    #
    # redirect_uri 有效时间是从扫码成功后算起大概是 300 秒，
    # 在此期间可以重新登录，但获取的联系人和群 ID 会改变
    def store_login_data(redirect_url)
      host = URI.parse(redirect_url).host
      r = @session.get(redirect_url)
      data = r.parse(:xml)

      store(
        skey: data["error"]["skey"],
        sid: data["error"]["wxsid"],
        uin: data["error"]["wxuin"],
        device_id: "e#{rand.to_s[2..17]}",
        pass_ticket: data["error"]["pass_ticket"],
      )

      @bot.config.servers.each do |server|
        if host == server[:index]
          update_servers(server)
          break
        end
      end

      raise RuntimeError, "没有匹配到对于的微信服务器: #{host}" unless store(:index_url)

      r
    end

    # 微信登录后初始化工作
    #
    # 掉线后 300 秒可以重新使用此 api 登录获取的联系人和群ID保持不变
    def login_loading
      url = api_url('webwxinit', r: timestamp)
      r = @session.post(url, json: params_base_request)
      data = r.parse(:json)

      store(
        sync_key: data["SyncKey"],
        invite_start_count: data["InviteStartCount"].to_i,
      )

      # 保存当前用户信息和最近聊天列表
      @bot.profile.parse(data["User"])
      @bot.contact_list.batch_sync(data["ContactList"])

      r
    end

    # 更新通知状态（关闭手机提醒通知）
    #
    # 需要解密参数 Code 的值的作用，目前都用的是 3
    def update_notice_status
      url = api_url('webwxstatusnotify', lang: 'zh_CN', pass_ticket: store(:pass_ticket))
      params = params_base_request.merge({
        "Code"  => 3,
        "FromUserName" => @bot.profile.username,
        "ToUserName" => @bot.profile.username,
        "ClientMsgId" => timestamp
      })

      r = @session.post(url, json: params)
      r
    end

    # 检查微信状态
    #
    # 状态会包含是否有新消息、用户状态变化等
    #
    # @return [Hash] 状态数据数组
    #  - :retcode
    #    - 0 成功
    #    - 1100 用户登出
    #    - 1101 用户在其他地方登录
    #  - :selector
    #    - 0 无消息
    #    - 2 新消息
    #    - 6 未知消息类型
    #    - 7 需要调用 {#sync_messages}
    def sync_check
      url = "#{store(:push_url)}/synccheck"
      params = {
        "r" => timestamp,
        "skey" => store(:skey),
        "sid" => store(:sid),
        "uin" => store(:uin),
        "deviceid" => store(:device_id),
        "synckey" => params_sync_key,
        "_" => timestamp,
      }

      r = @session.get(url, params: params, timeout: [10, 60])
      data = r.parse(:js)["synccheck"]

      # raise RuntimeException "微信数据同步异常，原始返回内容：#{r.to_s}" if data.nil?

      @bot.logger.debug "HeartBeat: retcode/selector #{data.nil? ? "exception" :  [data[:retcode], data[:selector]].join('/')}"
      data
    end

    # 获取微信消息数据
    #
    # 根据 {#sync_check} 接口返回有数据时需要调用该接口
    # @return [void]
    def sync_messages
      url = api_url('webwxsync', {
        "sid" => store(:sid),
        "skey" => store(:skey),
        "pass_ticket" => store(:pass_ticket)
      })
      params = params_base_request.merge({
        "SyncKey" => store(:sync_key),
        "rr" => "-#{timestamp}"
      })

      r = @session.post(url, json: params, timeout: [10, 60])
      data = r.parse(:json)

      @bot.logger.debug "Message: A/M/D/CM #{data["AddMsgCount"]}/#{data["ModContactCount"]}/#{data["DelContactCount"]}/#{data["ModChatRoomMemberCount"]}"

      store(:sync_key, data["SyncCheckKey"])

      # 更新已存在的群聊信息、增加新的群聊信息
      @bot.contact_list.batch_sync(data["ModContactList"]) if data["ModContactCount"] > 0

      if data["AddMsgCount"] > 0
        data["AddMsgList"].each do |msg|
          next if msg["FromUserName"] == @bot.profile.username

          message = Message.new(msg, @bot)

          events = [:message]
          events.push(:text) if message.kind == Message::Kind::Text
          events.push(:group) if msg["ToUserName"].include?("@@")

          events.each do |event, *args|
            @bot.handlers.dispatch(event, message, args)
          end
        end
      end

      data
    end

    # 获取所有联系人列表
    #
    # 好友、群组、订阅号、公众号和特殊号
    #
    # @return [Hash] 联系人列表
    def contacts
      url = api_url('webwxgetcontact', {
        "r" => timestamp,
        "pass_ticket" => store(:pass_ticket),
        "skey" => store(:skey)
      })

      r = @session.post(url, json: {})
      data = r.parse(:json)

      @bot.contact_list.batch_sync(data["MemberList"])
    end

    alias_method :_send, :send

    # 消息发送
    #
    # @param [Symbol] type 消息类型，未知类型默认走 :text
    #   - :text 文本
    #   - :emoticon 表情
    #   - :image 图片
    # @param [String] username
    # @param [String] content
    # @return [Hash<Object,Object>] 发送结果状态
    def send(type, username, content)
      case type
      when :emoticon
        send_emoticon(username, content)
      when :image
        send_image(username, content: content)
      else
        send_text(username, content)
      end
    end

    # 发送消息
    #
    # @param [String] username 目标UserName
    # @param [String] text 消息内容
    # @return [Hash<Object,Object>] 发送结果状态
    def send_text(username, text)
      url = api_url('webwxsendmsg')
      params = params_base_request.merge({
        "Scene" => 0,
        "Msg" => {
          "Type" => 1,
          "FromUserName" => @bot.profile.username,
          "ToUserName" => username,
          "Content" => text,
          "LocalID" => timestamp,
          "ClientMsgId" => timestamp,
        },
      })

      r = @session.post(url, json: params)
      r.parse(:json)
    end

    # FIXME: 上传图片出问题，未能解决
    def upload_image(username, file)
      url = "#{store(:file_url)}/webwxuploadmedia?f=json"
      
      filename = File.basename(file.path)
      content_type = {'png'=>'image/png', 'jpg'=>'image/jpeg', 'jpeg'=>'image/jpeg'}[filename.split('.').last.downcase] || 'application/octet-stream'
      md5 = Digest::MD5.file(file.path).hexdigest

      headers = {
        'Host' => 'file.wx.qq.com',
        'User-Agent' => 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10.10; rv:42.0) Gecko/20100101 Firefox/42.0',
        'Accept' => '*/*',
        'Accept-Language' => 'zh-CN,zh;q=0.9,en-US;q=0.8,en;q=0.7',
        'Accept-Encoding' => 'gzip, deflate, br',
        'Referer' => 'https://wx.qq.com/',
        'Origin' => 'https://wx.qq.com',
        'Connection' => 'Keep-Alive'
      }

      @media_cnt = 1 + (@media_cnt || -1)

      params = {
        'id' => "WU_FILE_#{@media_cnt}",
        'name' => filename,
        'type' => content_type,
        'lastModifiedDate' => 'Tue Sep 09 2014 17:47:23 GMT+0800 (CST)',
        'size' => file.size,
        'mediatype' => 'pic', # pic/video/doc
        'uploadmediarequest' => JSON.generate(
          params_base_request.merge({
            'UploadType' => 2,
            'ClientMediaId' => timestamp,
            'TotalLen' => file.size,
            'StartPos' => 0,
            'DataLen' => file.size,
            'MediaType' => 4,
            'FromUserName' => @bot.profile.username,
            'ToUserName' => username,
            'FileMd5' => md5
            })
          ),
        'webwx_data_ticket' => @session.cookie_of('webwx_data_ticket'),
        'pass_ticket' => store(:pass_ticket),
        'filename' => ::HTTP::FormData::File.new(file, content_type: content_type)
        }

      r = @session.post(url, form: params, headers: headers)

      # @bot.logger.info "Response: #{r.inspect}"

      r.parse(:json)
    end

    # 发送图片
    #
    # @param [String] username 目标 UserName
    # @param [String, File] 图片名或图片文件
    # @param [Hash] 非文本消息的参数（可选）
    # @return [Boolean] 发送结果状态
    def send_image(username, **opts)
      # if media_id.nil?
      #   media_id = upload_file(image)
      # end
      if opts[:media_id]
        conf = {"MediaId" => opts[:media_id], "Content" => ""}
      elsif opts[:image]
        media_id = upload_image(username, opts[:image])
        conf = {"MediaId" => media_id, "Content" => ""}
      elsif opts[:content]
        conf = {"MediaId" => "", "Content" => opts[:content]}
      else
        raise RuntimeException, "发送图片参数错误，须提供media_id或content"
      end

      url = "#{store(:index_url)}/webwxsendmsgimg?fun=async&f=json"

      params = params_base_request.merge({
        "Scene" => 0,
        "Msg" => {
          "Type" => 3,
          "FromUserName" => @bot.profile.username,
          "ToUserName" => username,
          "LocalID" => timestamp,
          "ClientMsgId" => timestamp,
        }.merge(conf)
      })

      r = @session.post(url, json: params)
      r.parse(:json)
    end

    # 发送表情
    #
    # 支持微信表情和自定义表情
    #
    # @param [String] username
    # @param [String] emoticon_id
    #
    # @return [Hash<Object,Object>] 发送结果状态
    def send_emoticon(username, emoticon_id)
      url = api_url('webwxsendemoticon', {
        'fun' => 'sys',
        'pass_ticket' => store(:pass_ticket),
        'lang' => 'zh_CN'
      })
      params = params_base_request.merge({
        "Scene" => 0,
        "Msg" => {
          "Type" => 47,
          'EmojiFlag' => 2,
          "FromUserName" => @bot.profile.username,
          "ToUserName" => username,
          "LocalID" => timestamp,
          "ClientMsgId" => timestamp,
        },
      })

      emoticon_key = emoticon_id.include?("@") ? "MediaId" : "EMoticonMd5"
      params["Msg"][emoticon_key] = emoticon_id

      r = @session.post(url, json: params)
      r.parse(:json)
    end

    # 下载图片
    #
    # @param [String] message_id
    # @return [TempFile]
    def download_image(message_id)
      url = api_url('webwxgetmsgimg')
      params = {
        "msgid" => message_id,
        "skey" => store(:skey)
      }

      r = @session.get(url, params: params)
      # body = r.body

      # FIXME: 不知道什么原因，下载的是空字节
      # 返回的 headers 是 {"Connection"=>"close", "Content-Length"=>"0"}
      temp_file = Tempfile.new(["emoticon", ".gif"])
      while data = r.readpartial
        temp_file.write data
      end
      temp_file.close

      temp_file
    end

    # 创建群组
    #
    # @param [Array<String>] users
    # @return [Hash<Object, Object>]
    def create_group(*users)
      url = api_url('webwxcreatechatroom', r: timestamp, pass_ticket: store(:pass_ticket))
      params = params_base_request.merge({
        "Topic" => "",
        "MemberCount" => users.size,
        "MemberList" => users.map { |u| { "UserName" => u } }
      })

      r = @session.post(url, json: params)
      r.parse(:json)
    end

    ##### 
    # 以下接口都参考：https://github.com/littlecodersh/ItChat/blob/master/itchat/components/contact.py

    # 更新群组
    def update_group(username, fun, update_key, update_value)
      url = api_url('webwxupdatechatroom', {fun: fun, pass_ticket: store(:pass_ticket)})
      params = params_base_request.merge({
        "ChatRoomName" => username,
        update_key => update_value
        })
      r = @session.post(url, json: params)
      r.parse(:json)
    end

    # 修改群组名称
    def set_group_name(username, name)
      update_group(username, 'modtopic', 'NewTopic', name)
    end

    # 删除群组成员
    def delete_group_member(username, *users)
      update_group(username, 'delmember', 'DelMemberList', users.join(","))
    end

    # 群组邀请
    def invite_group_member(username, *users)
      update_group(username, 'invitemember', 'InviteMemberList', users.join(","))
    end

    # 群组添加
    def add_group_member(username, *users)
      update_group(username, 'addmember', 'AddMemberList', users.join(","))
    end

    # 添加好友
    #
    # @param [Integer] status: 2-添加 3-接受
    def add_friend(username, status = 2, verify_content='')
      url = api_url('webwxverifyuser', {r: timestamp, pass_ticket: store(:pass_ticket)})
      params = params_base_request.merge({
        "Opcode" => status, # 3
        "VerifyUserListSize" => 1,
        "VerifyUserList" => [{
          "Value" => username,
          "VerifyUserTicket" => ''}],
        "VerifyContent" => verify_content,
        "SceneListCount" => 1,
        "SceneList" => [33],
        "skey" => store(:skey)
      })
      r = @session.post(url, json: params)
      r.parse(:json)
    end
    ##### 

    # 登出
    #
    # @return [void]
    def logout
      url = api_url('webwxlogout')
      params = {
        "redirect" => 1,
        "type"  => 1,
        "skey"  => store(:skey)
      }

      @session.get(url, params: params)

      @bot.logger.info "用户 [#{@bot.profile.nickname}] 登出成功！"
      clone!
    end

    # 获取登录状态
    #
    # @return [Boolean]
    def logged?
      @is_logged
    end

    # 获取是否在线（存活）
    #
    # @return [Boolean]
    def alive?
      @is_alive
    end

    private

    def api_url(path, query = {})
      "#{store(:index_url)}/#{path}#{query.empty? ? '' : '?'+URI.encode_www_form(query)}"
    end

    # 保存和获取存储数据
    #
    # @return [Object] 获取数据返回该变量对应的值类型
    # @return [void] 保存数据时无返回值
    def store(*args)
      return @store[args[0].to_sym] = args[1] if args.size == 2

      if args.size == 1
        obj = args[0]
        return @store[obj.to_sym] if obj.is_a?(String) || obj.is_a?(Symbol)

        obj.each do |key, value|
          @store[key.to_sym] = value
        end if obj.is_a?(Hash)
      end
    end

    # 生成 13 位 unix 时间戳
    # @return [String]
    def timestamp
      Time.now.strftime("%s%3N")
    end

    # 匹配对于的微信服务器
    #
    # @param [Hash<String, String>] servers
    # @return [void]
    def update_servers(servers)
      server_scheme = "https"
      server_path = "/cgi-bin/mmwebwx-bin"
      servers.each do |name, host|
        store("#{name}_url", "#{server_scheme}://#{host}#{server_path}")
      end
    end

    # 微信接口请求参数 BaseRequest
    #
    # @return [Hash<String, String>]
    def params_base_request
      return @base_request if @base_request

      @base_request = {
        "BaseRequest" => {
          "Skey" => store(:skey),
          "Sid" => store(:sid),
          "Uin" => store(:uin),
          "DeviceID" => store(:pass_ticket),
        }
      }
    end

    # 微信接口参数序列后的 SyncKey
    #
    # @return [void]
    def params_sync_key
      store(:sync_key)["List"].map { |i| i.values.join("_") }.join("|")
    end

    # 初始化变量
    #
    # @return [void]
    def clone!
      @session = HTTP::Session.new(@bot)
      @is_logged = @is_alive = false
      @store = {}
    end
  end
end
