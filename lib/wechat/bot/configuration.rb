module WeChat::Bot
  class Configuration < OpenStruct
    KnownOptions = []

    # Generate a default configuration.
    #
    # @return [Hash]
    def self.default_config
      {
        app_id: "wx782c26e4c19acffb",
        auth_url: "https://login.weixin.qq.com",
        servers: [
          {
            index: "wx.qq.com",
            file: "file.wx.qq.com",
            push: "webpush.wx.qq.com",
          },
          {
            index: "wx2.qq.com",
            file: "file.wx2.qq.com",
            push: "webpush.wx2.qq.com",
          },
          {
            index: "wx8.qq.com",
            file: "file.wx8.qq.com",
            push: "webpush.wx8.qq.com",
          },
          {
            index: "wechat.com",
            file: "file.web.wechat.com",
            push: "webpush.web.wechat.com",
          },
          {
            index: "web2.wechat.com",
            file: "file.web2.wechat.com",
            push: "webpush.web2.wechat.com",
          },
        ],
        cookies: "wechat-bot-cookies.txt",
        user_agent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_12_5) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/59.0.3071.86 Safari/537.36",
      }
    end

    def initialize(defaults = nil)
      defaults ||= self.class.default_config
      super(defaults)
    end

    # @return [Hash]
    def to_h
      @table.clone
    end

    def [](key)
      # FIXME also adjust method_missing
      raise ArgumentError, "Unknown option #{key}" unless self.class::KnownOptions.include?(key)
      @table[key]
    end

    def []=(key, value)
      # FIXME also adjust method_missing
      raise ArgumentError, "Unknown option #{key}" unless self.class::KnownOptions.include?(key)
      modifiable[new_ostruct_member(key)] = value
    end
  end
end
