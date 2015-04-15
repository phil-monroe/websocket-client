require 'pry'
require 'websocket'
require 'logger'
require 'socket'

module Websocket
  class Client
    attr_accessor :url, :options, :logger

    def initialize(url, opts = {})
      @callbacks = Hash.new
      @url       = url
      @options   = opts
      @logger    = options[:logger] || Logger.new(STDOUT).tap{ |l| l.level = 1}

      on(:ping)       { |message| send(message.data, :pong) }
      on(:disconnect) { stop }

      yield(self) if block_given?

      start
    end

    def on action, &block
      @callbacks[action] = block
    end

    def start
      stop if connected?
      @handshake = WebSocket::Handshake::Client.new(url: url, headers: options[:headers])
      @frame     = WebSocket::Frame::Incoming::Server.new(version: @handshake.version)

      connect
      handshake
      start_receiver_thread
      @started = true
      trigger(:start)
    rescue
      stop
      false
    end

    def stop
      return unless connected?
      @receive_thread.kill unless @receive_thread.nil?
      @socket.close        unless @socket.nil?
      @socket = @receive_thread = nil
      @started = false
      trigger(:stop)
      true
    end


    def send(data, type = :text)
      return false unless connected?

      data = WebSocket::Frame::Outgoing::Client.new(
      :version => @handshake.version,
      :data => data,
      :type => type
      ).to_s

      @socket.write data
      @socket.flush

      trigger :sent, data
      true
    end

    def connected?
      @started == true
    end

    private

    def connect
      @socket = TCPSocket.new(@handshake.host, @handshake.port || 80)
      if @handshake.secure
        ctx = OpenSSL::SSL::SSLContext.new
        if options[:ssl_verify]
          ctx.verify_mode = OpenSSL::SSL::VERIFY_PEER | OpenSSL::SSL::VERIFY_FAIL_IF_NO_PEER_CERT
          ctx.ca_file = options[:cert_file] # || CA_FILE
        else
          ctx.verify_mode = OpenSSL::SSL::VERIFY_NONE
        end

        ssl_sock = OpenSSL::SSL::SSLSocket.new(@socket, ctx)
        ssl_sock.sync_close = true
        ssl_sock.connect

        @socket = ssl_sock
      end
    end

    def handshake
      @socket.write(@handshake.to_s)
      @socket.flush

      loop do
        data = @socket.getc
        next if data.nil?

        @handshake << data

        if @handshake.finished?
          raise @handshake.error.to_s unless @handshake.valid?
          @handshaked = true
          break
        end
      end

      trigger :connect
    end

    def start_receiver_thread
      @receive_thread = Thread.new do
        loop do
          begin
            data = @socket.read_nonblock(1024)
          rescue Errno::EAGAIN, Errno::EWOULDBLOCK
            IO.select([@socket])
            retry
          rescue EOFError, Errno::EBADF
            trigger :disconnect
          end

          @frame << data

          while message = @frame.next
            if message.type === :ping
              trigger(:ping, message)
            else
              trigger(:receive, message.data)
            end
          end
        end
      end
    end

    def trigger action, *args
      Thread.new do
        logger.debug "#{action}: #{args}"
        @callbacks[action].call(*args) unless @callbacks[action].nil?
      end.join
    end
  end
end

if __FILE__ == $0
  Thread.abort_on_exception = true

  client = Websocket::Client.new "ws://localhost:9292/test", headers: {'WD_TOKEN': "FOO BAR BAZ"} do |conn|
    conn.on :receive do |data|
      puts data
    end

    conn.on :connect do |data|
      puts "woot"
    end

    conn.on :disconnect do
      puts "crap..."
      conn.stop
      until conn.start
        sleep 1
      end
    end
  end

  binding.pry
end