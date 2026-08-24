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
