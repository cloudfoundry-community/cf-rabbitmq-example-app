require 'spec_helper'
require 'rabbitmq/endpoint'
require 'rabbitmq/adapters/stomp'

RSpec.describe RabbitMQ::Adapters::Stomp do
  let(:endpoint) do
    RabbitMQ::Endpoint.new(
      protocol: 'stomp', host: 'broker.example', port: 61613, tls: false,
      username: 'app-user', password: 'p', vhost: 'demo-vhost',
      source: :derived, verify_peer: true
    )
  end

  it 'sends the vhost in the CONNECT host header' do
    opts = described_class.new(endpoint).connection_options
    expect(opts[:connect_headers]['host']).to eq('demo-vhost')
  end

  it 'negotiates modern protocol versions' do
    opts = described_class.new(endpoint).connection_options
    expect(opts[:connect_headers]['accept-version']).to eq('1.0,1.1,1.2')
  end

  it 'does not prefix the username, unlike MQTT' do
    expect(described_class.new(endpoint).connection_options[:hosts].first[:login])
      .to eq('app-user')
  end

  it 'passes host, port and ssl' do
    host = described_class.new(endpoint).connection_options[:hosts].first
    expect(host[:host]).to eq('broker.example')
    expect(host[:port]).to eq(61613)
    expect(host[:ssl]).to be(false)
  end

  it 'enables ssl for a TLS endpoint' do
    tls = endpoint.dup.tap { |e| e.tls = true; e.port = 61614 }
    expect(described_class.new(tls).connection_options[:hosts].first[:ssl]).to be(true)
  end

  it 'addresses queues under /queue/' do
    expect(described_class.new(endpoint).destination('alpha')).to eq('/queue/alpha')
  end

  it 'bounds the initial connect so an unreachable broker cannot hang forever' do
    opts = described_class.new(endpoint).connection_options
    expect(opts[:start_timeout]).to be > 0
  end

  describe '#consume' do
    it 'closes the client and unsubscribes even when the read times out' do
      client = instance_double(Stomp::Client, subscribe: nil, unsubscribe: nil, close: nil)
      allow(Stomp::Client).to receive(:new).and_return(client)
      allow(Timeout).to receive(:timeout).and_raise(Timeout::Error)

      status, body = described_class.new(endpoint).consume('alpha')

      expect(status).to eq(204)
      expect(body).to eq('')
      expect(client).to have_received(:unsubscribe).with('/queue/alpha')
      expect(client).to have_received(:close)
    end

    it 'still closes the client when construction itself raises' do
      allow(Stomp::Client).to receive(:new).and_raise(Stomp::Error::MaxReconnectAttempts.new)

      expect { described_class.new(endpoint).consume('alpha') }
        .to raise_error(Stomp::Error::MaxReconnectAttempts)
    end
  end
end
