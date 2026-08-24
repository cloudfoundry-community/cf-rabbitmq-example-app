require 'spec_helper'
require 'rabbitmq/endpoint'
require 'rabbitmq/adapters/management'

RSpec.describe RabbitMQ::Adapters::Management do
  let(:endpoint) do
    RabbitMQ::Endpoint.new(
      protocol: 'management', host: 'broker.example', port: 15672, tls: false,
      username: 'u', password: 'p', vhost: 'demo-vhost', source: :advertised,
      verify_peer: true
    )
  end

  subject(:api) { described_class.new(endpoint) }

  it 'reads the overview' do
    stub_request(:get, 'http://broker.example:15672/api/overview')
      .with(basic_auth: %w[u p])
      .to_return(body: '{"rabbitmq_version":"3.13.7"}', headers: { 'Content-Type' => 'application/json' })

    expect(api.overview['rabbitmq_version']).to eq('3.13.7')
  end

  it 'lists queues scoped to the bound vhost' do
    stub_request(:get, 'http://broker.example:15672/api/queues/demo-vhost')
      .to_return(body: '[{"name":"alpha","messages":3},{"name":"beta","messages":0}]',
                 headers: { 'Content-Type' => 'application/json' })

    expect(api.queue_names).to eq(%w[alpha beta])
  end

  it 'url-encodes the vhost' do
    slash = endpoint.dup.tap { |e| e.vhost = '/' }
    stub_request(:get, 'http://broker.example:15672/api/queues/%2F')
      .to_return(body: '[]', headers: { 'Content-Type' => 'application/json' })

    expect(described_class.new(slash).queue_names).to eq([])
  end

  it 'reports a queue as missing on 404' do
    stub_request(:get, 'http://broker.example:15672/api/queues/demo-vhost/nope')
      .to_return(status: 404, body: '{"error":"Object Not Found"}')

    expect(api.queue('nope')).to be_nil
    expect(api.queue_exists?('nope')).to be(false)
  end

  it 'uses https when the endpoint is TLS' do
    tls = endpoint.dup.tap { |e| e.tls = true; e.port = 15671 }
    stub_request(:get, 'https://broker.example:15671/api/overview')
      .to_return(body: '{}', headers: { 'Content-Type' => 'application/json' })

    expect(described_class.new(tls).overview).to eq({})
  end

  describe 'read-only behaviour' do
    it 'returns 501 NOT-SUPPORTED from declare, publish and consume' do
      expect(api.declare('q')).to eq([501, 'NOT-SUPPORTED: declare over management'])
      expect(api.publish('q', 'data')).to eq([501, 'NOT-SUPPORTED: publish over management'])
      expect(api.consume('q')).to eq([501, 'NOT-SUPPORTED: consume over management'])
    end
  end
end
