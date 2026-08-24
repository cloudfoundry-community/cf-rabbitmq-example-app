require 'spec_helper'
require 'app'

RSpec.describe 'bare routes' do
  def app
    Sinatra::Application
  end

  let(:amqp) { instance_double(RabbitMQ::Adapters::AMQP) }
  let(:mgmt) { instance_double(RabbitMQ::Adapters::Management) }

  before do
    ENV['VCAP_SERVICES'] = vcap_fixture('tls_off')
    allow(RabbitMQ::Adapters::AMQP).to receive(:new).and_return(amqp)
    allow(RabbitMQ::Adapters::Management).to receive(:new).and_return(mgmt)
  end

  describe 'booting' do
    it 'loads with a clean load path, as config.ru does' do
      output = `cd #{Dir.pwd} && APP_ENV=test bundle exec ruby -e 'require "./lib/app"' 2>&1`
      expect($?.success?).to be(true), "app failed to boot: #{output}"
    end
  end

  context 'when no service is bound' do
    before { ENV.delete('VCAP_SERVICES') }

    it 'returns 500 with binding instructions' do
      get '/ping'
      expect(last_response.status).to eq(500)
      expect(last_response.body).to match('You must bind a RabbitMQ service instance to this application.')
      expect(last_response.body).to match('cf bind-service <app-name> rabbitmq-instance')
    end
  end

  describe 'GET /ping' do
    it 'returns 200 OK' do
      allow(amqp).to receive(:ping).and_return([200, 'OK'])
      get '/ping'
      expect(last_response.status).to eq(200)
      expect(last_response.body).to eq('OK')
    end

    it 'returns 500 with the error when the broker refuses' do
      allow(amqp).to receive(:ping).and_raise(StandardError, 'connection refused')
      get '/ping'
      expect(last_response.status).to eq(500)
      expect(last_response.body).to match('ERR:connection refused')
    end
  end

  describe 'POST /queues' do
    it 'returns 201 SUCCESS with a name' do
      allow(mgmt).to receive(:queue_exists?).with('my-queue').and_return(false)
      allow(amqp).to receive(:declare).with('my-queue').and_return([201, 'SUCCESS'])
      post '/queues', name: 'my-queue'
      expect(last_response.status).to eq(201)
      expect(last_response.body).to eq('SUCCESS')
    end

    it 'returns 400 NO-NAME without a name' do
      post '/queues', nil
      expect(last_response.status).to eq(400)
      expect(last_response.body).to eq('NO-NAME')
    end

    it 'returns 304 EXISTS when the queue is already there' do
      allow(mgmt).to receive(:queue_exists?).with('dupe').and_return(true)
      post '/queues', name: 'dupe'
      expect(last_response.status).to eq(304)
    end
  end

  describe 'GET /queues' do
    it 'lists queue names from the management API, one per line' do
      allow(mgmt).to receive(:queue_names).and_return(%w[alpha beta])
      get '/queues'
      expect(last_response.status).to eq(200)
      expect(last_response.body).to eq("alpha\nbeta\n")
    end
  end

  describe 'PUT /queue/:name' do
    it 'returns 201 SUCCESS with data' do
      allow(amqp).to receive(:publish).with('q', 'hello').and_return([201, 'SUCCESS'])
      put '/queue/q', data: 'hello'
      expect(last_response.status).to eq(201)
      expect(last_response.body).to eq('SUCCESS')
    end

    it 'returns 400 NO-DATA without data' do
      put '/queue/q', nil
      expect(last_response.status).to eq(400)
      expect(last_response.body).to eq('NO-DATA')
    end

    it 'returns 404 NO-SUCH-QUEUE when the queue is missing' do
      allow(amqp).to receive(:publish).and_raise(RabbitMQ::Adapters::QueueNotFound, 'q')
      put '/queue/q', data: 'hello'
      expect(last_response.status).to eq(404)
      expect(last_response.body).to eq('NO-SUCH-QUEUE')
    end
  end

  describe 'GET /queue/:name' do
    it 'returns 404 NO-SUCH-QUEUE for a missing queue' do
      allow(amqp).to receive(:consume).and_raise(RabbitMQ::Adapters::QueueNotFound, 'enoent')
      get '/queue/enoent'
      expect(last_response.status).to eq(404)
      expect(last_response.body).to eq('NO-SUCH-QUEUE')
    end

    it 'returns 204 for an empty queue' do
      allow(amqp).to receive(:consume).with('empty').and_return([204, ''])
      get '/queue/empty'
      expect(last_response.status).to eq(204)
    end

    it 'returns 200 and the message for a non-empty queue' do
      allow(amqp).to receive(:consume).with('full').and_return([200, "a message\n"])
      get '/queue/full'
      expect(last_response.status).to eq(200)
      expect(last_response.body).to eq("a message\n")
    end
  end

  describe 'GET /env' do
    it 'reports the resolved uri without credentials' do
      get '/env'
      expect(last_response.status).to eq(200)
      expect(last_response.body).to eq("rabbitmq_url: amqp://10.7.16.17:5672\n")
      expect(last_response.body).not_to include('app-pass')
    end
  end

  describe 'protocol selection' do
    it 'defaults to amqp with no cookie and no param' do
      allow(amqp).to receive(:ping).and_return([200, 'OK'])
      get '/ping'
      expect(last_response.status).to eq(200)
    end

    it 'falls back to amqp for an unknown protocol name' do
      allow(amqp).to receive(:ping).and_return([200, 'OK'])
      get '/ping', { protocol: 'nonsense' }
      expect(last_response.status).to eq(200)
    end

    it 'falls back to amqp for a protocol the binding cannot resolve' do
      allow(amqp).to receive(:ping).and_return([200, 'OK'])
      get '/ping', { protocol: 'web_stomp_tls' }
      expect(last_response.status).to eq(200)
    end

    it 'selects the protocol from the cookie when no param is given' do
      allow(mgmt).to receive(:ping).and_return([200, 'MGMT-OK'])
      set_cookie 'rmq_protocol=management'
      get '/ping'
      expect(last_response.status).to eq(200)
      expect(last_response.body).to eq('MGMT-OK')
    end

    it 'prefers the query param over the cookie' do
      allow(amqp).to receive(:ping).and_return([200, 'OK'])
      set_cookie 'rmq_protocol=management'
      get '/ping', { protocol: 'amqp' }
      expect(last_response.status).to eq(200)
      expect(last_response.body).to eq('OK')
    end
  end

  describe 'management errors' do
    it 'returns 502 with the upstream status and detail' do
      allow(mgmt).to receive(:queue_names)
        .and_raise(RabbitMQ::Adapters::ManagementError.new(401, 'Access refused'))
      get '/queues'
      expect(last_response.status).to eq(502)
      expect(last_response.body).to eq('ERR:management API returned 401: Access refused')
    end
  end
end
