require 'spec_helper'
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
    expect(adapter.client_id).to eq('cf-rabbitmq-example-app-3')
  end

  it 'falls back to instance 0 when CF_INSTANCE_INDEX is absent' do
    adapter = described_class.new(endpoint)
    allow(ENV).to receive(:[]).with('CF_INSTANCE_INDEX').and_return(nil)
    expect(adapter.client_id).to eq('cf-rabbitmq-example-app-0')
  end

  it 'defaults to the serialized strategy' do
    expect(described_class.new(endpoint).strategy).to eq('serialized')
  end

  it 'falls back to serialized for an unknown strategy' do
    expect(described_class.new(endpoint, strategy: 'nonsense').strategy).to eq('serialized')
  end

  it 'derives a per-queue client id from the queue name' do
    adapter = described_class.new(endpoint, strategy: 'per-queue')
    expect(adapter.client_id('alpha')).to end_with('-alpha')
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
end
