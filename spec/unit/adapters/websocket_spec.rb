require 'spec_helper'
require 'mqtt'
require 'rabbitmq/endpoint'
require 'rabbitmq/adapters/websocket'

# A minimal double for WebSocket::Client::Simple::Client: records
# registered handlers and lets a test fire them synchronously, standing
# in for the gem's own background-thread-driven socket.
#
# #fire dispatches via instance_exec, exactly like the real gem's
# dependency: websocket-client-simple's Client#connect (via EventEmitter#on)
# and #emit (event_emitter-0.2.6/lib/event_emitter/emitter.rb) run every
# registered listener with `instance_exec(*data, &listener)`, which rebinds
# `self` to the emitter (the Client) for the duration of the block. A fake
# that instead used a plain `#call` would leave `self` as whatever defined
# the handler - a real gap once: the adapter's :open handler referenced a
# private adapter method (connect_frame) as a bare call, which only failed
# against the real gem's instance_exec dispatch, not against a #call-based
# fake. Dispatching the same way here is what makes this fake trustworthy
# as a stand-in.
class FakeWSSocket
  attr_reader :sent

  def initialize
    @handlers = {}
  end

  def on(event, &block)
    @handlers[event] = block
  end

  def send(data, _opts = {})
    @sent = data
  end

  def close; end

  def fire(event, *args)
    handler = @handlers[event]
    return unless handler

    instance_exec(*args, &handler)
  end
end

RSpec.describe 'websocket adapters' do
  def endpoint_for(protocol, port, tls)
    RabbitMQ::Endpoint.new(
      protocol: protocol, host: 'broker.example', port: port, tls: tls,
      username: 'demo-vhost:app-user', password: 'p', vhost: 'demo-vhost',
      source: :derived, verify_peer: true
    )
  end

  describe RabbitMQ::Adapters::WebMQTT do
    subject(:adapter) { described_class.new(endpoint_for('web_mqtt', 15675, false)) }

    it 'builds a ws url on the web-mqtt path' do
      expect(adapter.url).to eq('ws://broker.example:15675/ws')
    end

    it 'negotiates the mqtt subprotocol' do
      expect(adapter.subprotocol).to eq('mqtt')
    end

    it 'builds a wss url for a TLS endpoint' do
      tls = described_class.new(endpoint_for('web_mqtt_tls', 15676, true))
      expect(tls.url).to eq('wss://broker.example:15676/ws')
    end

    it 'refuses publish, directing to the browser demo' do
      code, body = adapter.publish('q', 'hello')
      expect(code).to eq(501)
      expect(body).to match(%r{/web-mqtt/demo})
    end

    it 'refuses consume, directing to the browser demo' do
      code, body = adapter.consume('q')
      expect(code).to eq(501)
      expect(body).to match(%r{/web-mqtt/demo})
    end

    describe 'frame construction' do
      it 'builds a complete wire-format CONNECT packet, not a description' do
        frame = adapter.send(:connect_frame)
        expect(frame.encoding).to eq(Encoding::ASCII_8BIT)
        parsed = MQTT::Packet.parse(frame)
        expect(parsed).to be_a(MQTT::Packet::Connect)
        expect(parsed.username).to eq('demo-vhost:app-user')
      end

      it 'recognises a zero-return-code CONNACK as acknowledged' do
        connack = MQTT::Packet::Connack.new(return_code: 0).to_s
        expect(adapter.send(:acknowledged?, connack)).to be(true)
      end

      it 'rejects a non-zero-return-code CONNACK' do
        connack = MQTT::Packet::Connack.new(return_code: 5).to_s
        expect(adapter.send(:acknowledged?, connack)).to be(false)
      end

      it 'rejects a frame that does not parse as MQTT at all' do
        expect(adapter.send(:acknowledged?, 'not an mqtt frame')).to be(false)
      end
    end

    describe '#ping' do
      let(:socket) { FakeWSSocket.new }

      # The fake fires :open synchronously, inside the same call that
      # registers the handlers - exactly mirroring the requirement that
      # handlers must be attached via the connect block, before the real
      # gem's background thread could otherwise race them.
      before do
        allow(::WebSocket::Client::Simple).to receive(:connect) do |_url, _opts, &blk|
          blk.call(socket)
          socket.fire(:open)
          socket
        end
      end

      it 'registers handlers via the connect block, before the socket starts reading' do
        expect(::WebSocket::Client::Simple).to receive(:connect) do |_url, _opts, &blk|
          expect(blk).not_to be_nil
          blk.call(socket)
          socket.fire(:open)
          socket.fire(:message, double(data: MQTT::Packet::Connack.new(return_code: 0).to_s))
          socket
        end

        adapter.ping

        expect(socket.sent).to eq(adapter.send(:connect_frame))
      end

      it 'returns 200 when the broker acknowledges the CONNECT' do
        allow(socket).to receive(:send) do
          socket.fire(:message, double(data: MQTT::Packet::Connack.new(return_code: 0).to_s))
        end

        expect(adapter.ping).to eq([200, 'OK'])
      end

      it 'returns 502 when the handshake response is not an acknowledgement' do
        allow(socket).to receive(:send) { socket.fire(:message, double(data: 'garbage')) }

        status, body = adapter.ping
        expect(status).to eq(502)
        expect(body).to match(/unexpected handshake response/)
      end

      it 'returns 504 rather than hanging when the server never responds' do
        allow(Timeout).to receive(:timeout).and_raise(Timeout::Error)

        status, body = adapter.ping
        expect(status).to eq(504)
        expect(body).to match(/no handshake response/)
      end

      it 'closes the socket even when the handshake times out' do
        # A real (but tiny) timeout, rather than a stub, so this exercises
        # the actual path where the connection succeeds but nothing ever
        # answers - proving the socket obtained before the timeout fires
        # still gets closed, not just the no-connection-at-all case above.
        stub_const('RabbitMQ::Adapters::WebSocket::HANDSHAKE_TIMEOUT', 0.1)
        allow(socket).to receive(:close)

        status, = adapter.ping

        expect(status).to eq(504)
        expect(socket).to have_received(:close)
      end
    end
  end

  describe RabbitMQ::Adapters::WebStomp do
    subject(:adapter) { described_class.new(endpoint_for('web_stomp', 15674, false)) }

    it 'builds a ws url on the web-stomp path' do
      expect(adapter.url).to eq('ws://broker.example:15674/ws')
    end

    it 'negotiates a stomp subprotocol' do
      expect(adapter.subprotocol).to eq('v12.stomp')
    end

    describe 'frame construction' do
      it 'builds a CONNECT frame carrying the vhost and credentials' do
        frame = adapter.send(:connect_frame)
        expect(frame).to include("host:demo-vhost")
        expect(frame).to include("login:demo-vhost:app-user")
        expect(frame).to include("passcode:p")
        expect(frame).to end_with("\0")
      end

      it 'recognises a CONNECTED frame as acknowledged' do
        expect(adapter.send(:acknowledged?, "CONNECTED\nversion:1.2\n\n\0")).to be(true)
      end

      it 'rejects an ERROR frame' do
        expect(adapter.send(:acknowledged?, "ERROR\nmessage:bad login\n\n\0")).to be(false)
      end
    end

    describe '#ping' do
      let(:socket) { FakeWSSocket.new }

      before do
        allow(::WebSocket::Client::Simple).to receive(:connect) do |_url, _opts, &blk|
          blk.call(socket)
          socket.fire(:open)
          socket
        end
      end

      it 'returns 200 when the broker sends CONNECTED' do
        allow(socket).to receive(:send) { socket.fire(:message, double(data: "CONNECTED\nversion:1.2\n\n\0")) }

        expect(adapter.ping).to eq([200, 'OK'])
      end
    end
  end
end
