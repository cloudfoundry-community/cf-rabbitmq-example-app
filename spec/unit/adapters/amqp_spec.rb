require 'spec_helper'
require 'rabbitmq/endpoint'
require 'rabbitmq/adapters/amqp'

RSpec.describe RabbitMQ::Adapters::AMQP do
  let(:endpoint) do
    RabbitMQ::Endpoint.new(
      protocol: 'amqps', host: 'broker.example', port: 5671, tls: true,
      username: 'u', password: 'p', vhost: 'v', source: :advertised, verify_peer: true
    )
  end

  describe '#connection_options' do
    it 'passes :tls and :port explicitly' do
      opts = described_class.new(endpoint).connection_options
      expect(opts[:tls]).to be(true)
      expect(opts[:port]).to eq(5671)
      expect(opts[:host]).to eq('broker.example')
    end

    it 'passes verify_peer through' do
      expect(described_class.new(endpoint).connection_options[:verify_peer]).to be(true)
    end

    it 'passes the vhost and credentials' do
      opts = described_class.new(endpoint).connection_options
      expect(opts[:vhost]).to eq('v')
      expect(opts[:username]).to eq('u')
      expect(opts[:password]).to eq('p')
    end

    it 'disables tls for a plaintext endpoint' do
      plain = endpoint.dup.tap { |e| e.tls = false; e.port = 5672 }
      opts = described_class.new(plain).connection_options
      expect(opts[:tls]).to be(false)
      expect(opts[:port]).to eq(5672)
    end
  end

  describe '#publish' do
    let(:channel) { instance_double(Bunny::Channel) }
    let(:connection) { instance_double(Bunny::Session, start: nil, create_channel: channel, close: nil) }
    let(:exchange) { instance_double(Bunny::Exchange, publish: nil) }

    before do
      allow(Bunny).to receive(:new).and_return(connection)
      allow(channel).to receive(:default_exchange).and_return(exchange)
    end

    it 'requires the queue to already exist, rather than creating it' do
      queue = instance_double(Bunny::Queue)
      allow(channel).to receive(:queue).with('q', durable: false, passive: true).and_return(queue)

      status, body = described_class.new(endpoint).publish('q', 'hello')

      expect(channel).to have_received(:queue).with('q', durable: false, passive: true)
      expect(status).to eq(201)
      expect(body).to eq('SUCCESS')
    end

    it 'raises QueueNotFound instead of silently creating the queue' do
      allow(channel).to receive(:queue).and_raise(Bunny::NotFound.new('not found', nil, nil))

      expect { described_class.new(endpoint).publish('missing', 'hello') }
        .to raise_error(RabbitMQ::Adapters::QueueNotFound)
    end
  end
end

RSpec.describe RabbitMQ::Adapters::AMQP, 'when the connection fails' do
  let(:endpoint) do
    RabbitMQ::Endpoint.new(
      protocol: 'amqps', host: 'broker.example', port: 5671, tls: true,
      username: 'u', password: 'p', vhost: 'v', source: :advertised,
      verify_peer: true
    )
  end

  let(:connection) { instance_double(Bunny::Session) }

  before { allow(Bunny).to receive(:new).and_return(connection) }

  # Bunny says exactly the right thing about a bad certificate
  # ("certificate verify failed (self-signed certificate in certificate
  # chain)", or "hostname ... does not match the server certificate") -
  # and the operator never saw either. Closing a connection that never
  # opened makes Bunny write a Close frame down a dead socket, and that
  # exception, raised from `ensure`, replaced the real one: the two cases
  # above surfaced as "ERR:SSL_write" and "ERR:Timeout::Error".
  it 'reports the real failure, not whatever closing the dead socket raises' do
    allow(connection).to receive(:start)
      .and_raise(OpenSSL::SSL::SSLError.new('certificate verify failed'))
    allow(connection).to receive(:close).and_raise(OpenSSL::SSL::SSLError.new('SSL_write'))

    expect { described_class.new(endpoint).ping }
      .to raise_error(OpenSSL::SSL::SSLError, /certificate verify failed/)
  end

  it 'still returns the result when only the close fails' do
    channel = instance_double(Bunny::Channel)
    allow(connection).to receive(:start)
    allow(connection).to receive(:create_channel).and_return(channel)
    allow(connection).to receive(:close).and_raise(IOError, 'closed stream')

    expect(described_class.new(endpoint).ping).to eq([200, 'OK'])
  end

  it 'still closes the connection on the happy path' do
    channel = instance_double(Bunny::Channel)
    allow(connection).to receive(:start)
    allow(connection).to receive(:create_channel).and_return(channel)
    allow(connection).to receive(:close)

    described_class.new(endpoint).ping

    expect(connection).to have_received(:close).once
  end
end
