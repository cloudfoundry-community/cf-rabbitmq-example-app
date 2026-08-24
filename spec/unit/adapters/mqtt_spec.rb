require 'spec_helper'
require 'mqtt'
require 'rabbitmq/endpoint'
require 'rabbitmq/adapters/mqtt'

RSpec.describe RabbitMQ::Adapters::MQTT do
  let(:endpoint) do
    RabbitMQ::Endpoint.new(
      protocol: 'mqtt', host: 'broker.example', port: 1883, tls: false,
      username: 'demo-vhost:app-user', password: 'p', vhost: 'demo-vhost',
      source: :derived, verify_peer: true
    )
  end

  it 'passes the vhost-prefixed username through untouched' do
    expect(described_class.new(endpoint).connection_options[:username])
      .to eq('demo-vhost:app-user')
  end

  it 'passes host, port and ssl' do
    opts = described_class.new(endpoint).connection_options
    expect(opts[:host]).to eq('broker.example')
    expect(opts[:port]).to eq(1883)
    expect(opts[:ssl]).to be(false)
  end

  it 'enables ssl for a TLS endpoint' do
    tls = endpoint.dup.tap { |e| e.tls = true; e.port = 8883 }
    expect(described_class.new(tls).connection_options[:ssl]).to be(true)
  end

  it 'derives a per-instance client id so instances do not evict each other' do
    adapter = described_class.new(endpoint)
    allow(ENV).to receive(:[]).with('CF_INSTANCE_INDEX').and_return('3')
    expect(adapter.client_id).to eq('cfrmq-3')
  end

  it 'falls back to instance 0 when CF_INSTANCE_INDEX is absent' do
    adapter = described_class.new(endpoint)
    allow(ENV).to receive(:[]).with('CF_INSTANCE_INDEX').and_return(nil)
    expect(adapter.client_id).to eq('cfrmq-0')
  end

  it 'defaults to the serialized strategy' do
    expect(described_class.new(endpoint).strategy).to eq('serialized')
  end

  it 'falls back to serialized for an unknown strategy' do
    expect(described_class.new(endpoint, strategy: 'nonsense').strategy).to eq('serialized')
  end

  it 'derives a stable, distinct client id per queue' do
    adapter = described_class.new(endpoint, strategy: 'per-queue')
    expect(adapter.client_id('alpha')).to eq(adapter.client_id('alpha'))
    expect(adapter.client_id('alpha')).not_to eq(adapter.client_id('beta'))
  end

  it 'derives a distinct client id per request' do
    adapter = described_class.new(endpoint, strategy: 'per-request')
    expect(adapter.client_id('alpha')).not_to eq(adapter.client_id('alpha'))
  end

  it 'refuses to consume under per-request rather than returning an empty queue' do
    adapter = described_class.new(endpoint, strategy: 'per-request')
    code, body = adapter.consume('alpha')
    expect(code).to eq(409)
    expect(body).to match(/per-request cannot see a prior subscribe/)
  end

  describe '#declare' do
    # ruby-mqtt's Client#subscribe is fire-and-forget - it never waits for
    # a SUBACK, and Client#handle_packet (mqtt-0.7.0) explicitly ignores
    # every one it receives. Disconnecting right after #subscribe used to
    # race the broker's own processing of it, losing the very next
    # publish (reproduced against a real broker: 0/15 recoveries with no
    # gap). A QoS-1 publish genuinely blocks for a broker round trip, and
    # a broker processes packets on one connection in order, so flushing
    # with one after subscribing - before disconnecting - guarantees the
    # SUBSCRIBE was already processed. This is the one thing a unit spec
    # can prove about the fix; that it actually rescues the message is
    # spec/integration/mqtt_concurrency_spec.rb's job, against a real
    # broker.
    it 'subscribes, then flushes with a QoS-1 publish before disconnecting' do
      client = instance_double(::MQTT::Client, subscribe: nil, publish: nil)
      allow(::MQTT::Client).to receive(:new).and_return(client)
      allow(client).to receive(:connect).and_yield(client)

      code, body = described_class.new(endpoint).declare('some-queue')

      expect(client).to have_received(:subscribe).with('some-queue' => 1).ordered
      expect(client).to have_received(:publish)
        .with(described_class::FLUSH_TOPIC, '', false, 1).ordered
      expect(code).to eq(201)
      expect(body).to eq('SUCCESS')
    end

    it 'flushes on a topic distinct from any queue name a caller could declare' do
      expect(described_class::FLUSH_TOPIC).not_to eq('some-queue')
    end
  end

  describe 'the MQTT wire format limit' do
    # ruby-mqtt raises "Client identifier too long" above 23 bytes,
    # regardless of protocol version, at serialisation time - a queue
    # name is caller-supplied and unbounded, so this has to hold for an
    # arbitrarily long one too, not just the short names used elsewhere
    # in this file.
    it 'keeps every strategy client id within 23 bytes, even for a long queue name' do
      long_queue = 'a' * 200
      %w[serialized per-queue per-request].each do |strategy|
        id = described_class.new(endpoint, strategy: strategy).client_id(long_queue)
        expect(id.bytesize).to be <= 23, "#{strategy} client_id #{id.inspect} is #{id.bytesize} bytes"
      end
    end

    it 'produces a client id ruby-mqtt can actually serialise into a CONNECT packet' do
      id = described_class.new(endpoint).client_id
      expect { MQTT::Packet::Connect.new(client_id: id, clean_session: true).to_s }
        .not_to raise_error
    end
  end
end

RSpec.describe RabbitMQ::Adapters::MQTT, 'over TLS' do
  def tls_endpoint(verify_peer)
    RabbitMQ::Endpoint.new(
      protocol: 'mqtts', host: 'broker.example', port: 8883, tls: true,
      username: 'demo-vhost:app-user', password: 'p', vhost: 'demo-vhost',
      source: :derived, verify_peer: verify_peer
    )
  end

  let(:context) { OpenSSL::SSL::SSLContext.new }
  let(:client) { instance_double(::MQTT::Client, ssl_context: context) }

  before do
    allow(::MQTT::Client).to receive(:new).and_return(client)
    allow(client).to receive(:connect).and_yield(client)
  end

  # ruby-mqtt's own SSLContext is created with no verify_mode, so before
  # this the adapter completed a TLS handshake against any certificate at
  # all. Confirmed against a broker holding a certificate from a CA in no
  # trust store: /mqtts/ping returned 200 OK.
  it 'verifies the broker certificate chain by default' do
    RabbitMQ::Adapters::MQTT.new(tls_endpoint(true)).ping

    expect(context.verify_mode).to eq(OpenSSL::SSL::VERIFY_PEER)
    expect(context.cert_store).not_to be_nil
  end

  it 'skips verification when the operator opted out' do
    RabbitMQ::Adapters::MQTT.new(tls_endpoint(false)).ping

    expect(context.verify_mode).to eq(OpenSSL::SSL::VERIFY_NONE)
  end

  # Touching ssl_context on a plaintext endpoint would build a context
  # ruby-mqtt never uses; more importantly it would read as though the
  # adapter thought it was securing something.
  it 'leaves the ssl context alone for a plaintext endpoint' do
    plain = RabbitMQ::Endpoint.new(
      protocol: 'mqtt', host: 'broker.example', port: 1883, tls: false,
      username: 'demo-vhost:app-user', password: 'p', vhost: 'demo-vhost',
      source: :derived, verify_peer: true
    )
    expect(client).not_to receive(:ssl_context)

    RabbitMQ::Adapters::MQTT.new(plain).ping
  end
end
