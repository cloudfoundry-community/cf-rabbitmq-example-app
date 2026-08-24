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

  describe 'upstream error handling' do
    it 'raises ManagementError with the status and reason on a 401' do
      stub_request(:get, 'http://broker.example:15672/api/overview')
        .to_return(status: 401,
                   body: '{"error":"not_authorised","reason":"Login failed"}',
                   headers: { 'Content-Type' => 'application/json' })

      expect { api.overview }.to raise_error(RabbitMQ::Adapters::ManagementError) do |error|
        expect(error.status).to eq(401)
        expect(error.detail).to include('Login failed')
      end
    end

    it 'raises ManagementError with the body text on a non-JSON 503' do
      stub_request(:get, 'http://broker.example:15672/api/overview')
        .to_return(status: 503, body: 'Service Unavailable', headers: { 'Content-Type' => 'text/plain' })

      expect { api.overview }.to raise_error(RabbitMQ::Adapters::ManagementError) do |error|
        expect(error.status).to eq(503)
        expect(error.detail).to include('Service Unavailable')
      end
    end

    it 'raises ManagementError, not JSON::ParserError, on a 200 with an HTML body' do
      stub_request(:get, 'http://broker.example:15672/api/overview')
        .to_return(status: 200, body: '<html><body>welcome</body></html>',
                   headers: { 'Content-Type' => 'text/html' })

      expect { api.overview }.to raise_error(RabbitMQ::Adapters::ManagementError) do |error|
        expect(error.status).to eq(200)
      end
    end

    it 'truncates a long detail so an HTML blob cannot reach the response' do
      long_body = "<html>#{'x' * 500}</html>"
      stub_request(:get, 'http://broker.example:15672/api/overview')
        .to_return(status: 502, body: long_body, headers: { 'Content-Type' => 'text/html' })

      expect { api.overview }.to raise_error(RabbitMQ::Adapters::ManagementError) do |error|
        expect(error.detail.length).to be <= (RabbitMQ::Adapters::ManagementError::DETAIL_LIMIT + 3)
        expect(error.detail).to end_with('...')
        expect(error.message).to end_with('...')
      end
    end

    it 'still returns nil on 404, never raising ManagementError' do
      stub_request(:get, 'http://broker.example:15672/api/queues/demo-vhost/nope')
        .to_return(status: 404, body: '{"error":"Object Not Found"}')

      expect(api.queue('nope')).to be_nil
    end
  end
end
