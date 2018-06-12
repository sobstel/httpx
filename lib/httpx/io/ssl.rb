# frozen_string_literal: true

require "openssl"

module HTTPX
  class SSL < TCP
    TLS_OPTIONS = if OpenSSL::SSL::SSLContext.instance_methods.include?(:alpn_protocols)
      { alpn_protocols: %w[h2 http/1.1] }
    else
      {}
    end

    def initialize(_, options)
      @ctx = OpenSSL::SSL::SSLContext.new
      ctx_options = TLS_OPTIONS.merge(options.ssl)
      @ctx.set_params(ctx_options) unless ctx_options.empty?
      super
      @state = :negotiated if @keep_open
    end

    def scheme
      "https"
    end

    def protocol
      @io.alpn_protocol || super
    rescue StandardError
      super
    end

    def close
      super
      # allow reconnections
      # connect only works if initial @io is a socket
      @io = @io.io if @io.respond_to?(:io)
      @negotiated = false
    end

    def connected?
      @state == :negotiated
    end

    def connect
      super
      if @keep_open
        @state = :negotiated
        return
      end
      return if @state == :negotiated ||
                @state != :connected
      unless @io.is_a?(OpenSSL::SSL::SSLSocket)
        @io = OpenSSL::SSL::SSLSocket.new(@io, @ctx)
        @io.hostname = @hostname
        @io.sync_close = true
      end
      @io.connect_nonblock
      @io.post_connection_check(@hostname) if @ctx.verify_mode != OpenSSL::SSL::VERIFY_NONE
      transition(:negotiated)
    rescue ::IO::WaitReadable,
           ::IO::WaitWritable
    end

    if RUBY_VERSION < "2.3"
      def read(*)
        super
      rescue ::IO::WaitWritable
        0
      end

      def write(*)
        super
      rescue ::IO::WaitReadable
        0
      end
    else
      if OpenSSL::VERSION < "2.0.6"
        def read(size, buffer)
          @io.read_nonblock(size, buffer)
          buffer.bytesize
        rescue ::IO::WaitReadable,
               ::IO::WaitWritable
          0
        rescue EOFError
          nil
        end
      end
    end

    def inspect
      id = @io.closed? ? "closed" : @io.to_io.fileno
      "#<SSL(fd: #{id}): #{@ip}:#{@port} state: #{@state}>"
    end

    private

    def transition(nextstate)
      case nextstate
      when :negotiated
        return unless @state == :connected
      when :closed
        return unless @state == :negotiated ||
                      @state == :connected
      end
      do_transition(nextstate)
    end
  end
end
