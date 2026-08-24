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
