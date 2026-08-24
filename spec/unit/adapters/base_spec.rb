require 'spec_helper'
require 'rabbitmq/endpoint'
require 'rabbitmq/adapters/base'

RSpec.describe RabbitMQ::Adapters::Base do
  let(:endpoint) do
    RabbitMQ::Endpoint.new(
      protocol: 'management', host: 'broker.example', port: 15672, tls: false,
      username: 'u', password: 'p', vhost: 'v', source: :advertised, verify_peer: false
    )
  end

  # A bare subclass implementing only #ping, as a read-only adapter
  # (e.g. management) would.
  let(:read_only_adapter_class) do
    Class.new(RabbitMQ::Adapters::Base) do
      def ping
        [200, 'OK']
      end
    end
  end

  subject(:adapter) { read_only_adapter_class.new(endpoint) }

  describe '#declare' do
    it 'returns 501 with a NOT-SUPPORTED body naming the verb and protocol' do
      status, body = adapter.declare('q')
      expect(status).to eq(501)
      expect(body).to eq('NOT-SUPPORTED: declare over management')
    end
  end

  describe '#publish' do
    it 'returns 501 with a NOT-SUPPORTED body naming the verb and protocol' do
      status, body = adapter.publish('q', 'data')
      expect(status).to eq(501)
      expect(body).to eq('NOT-SUPPORTED: publish over management')
    end
  end

  describe '#consume' do
    it 'returns 501 with a NOT-SUPPORTED body naming the verb and protocol' do
      status, body = adapter.consume('q')
      expect(status).to eq(501)
      expect(body).to eq('NOT-SUPPORTED: consume over management')
    end
  end

  describe '#ping' do
    it 'raises NotImplementedError when a subclass does not override it' do
      bare_class = Class.new(RabbitMQ::Adapters::Base)
      expect { bare_class.new(endpoint).ping }.to raise_error(NotImplementedError)
    end
  end
end
