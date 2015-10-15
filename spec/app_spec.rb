require 'spec_helper'
require 'json'

require 'app'

describe 'app' do

  def app
    Sinatra::Application.new
  end

  def without_vcap_services
    vcap_services = ENV.delete("VCAP_SERVICES")
    yield
    ENV.store("VCAP_SERVICES", vcap_services)
  end

  context 'when there is no rabbitmq instance bound' do
    it 'returns 500 INTERNAL SERVICE ERROR' do
      without_vcap_services do
        get '/ping'
        expect(last_response.status).to eq(500)
      end
    end

    it 'returns binding instructions' do
      without_vcap_services do
        get '/ping'
        expect(last_response.body).to match('You must bind a RabbitMQ service instance to this application.')
        expect(last_response.body).to match('You can run the following commands to create an instance and bind to it:')
        expect(last_response.body).to match('\$ cf create-service p-rabbitmq development rabbitmq-instance')
        expect(last_response.body).to match('\$ cf bind-service <app-name> rabbitmq-instance')
      end
    end
  end

  context 'when there is a rabbitmq instance bound' do
    before do
      ENV["VCAP_SERVICES"] ||= {
        'rabbitmq' => [{
           'name' => 'rabbitmq',
           'label' => 'rabbitmq',
           'tags' => [
              'rabbitmq',
              'pivotal'
           ],
           'plan' => 'default',
           'credentials' => {
             'uri'  => RABBITMQ.uri
           }
        }]
      }.to_json
    end

    describe 'initially' do
      it 'starts up' do
        60.times do
          get '/ping'
          break if last_response.status == 200
          sleep 1
        end
      end
    end

    describe 'GET /ping' do
      it 'returns 200 OK' do
        get '/ping'
        expect(last_response.status).to eq(200)
      end
    end

    describe 'POST /queues' do
      context 'with a name' do
        let(:payload) { { name: 'my-queue' } }

        it 'returns 201 Created' do
          post '/queues', payload
          expect(last_response.status).to eq(201)
          expect(last_response.body).to match('SUCCESS')
        end
      end

      context 'without a name' do
        it 'returns 400 Bad Request' do
          post '/queues', nil
          expect(last_response.status).to eq(400)
          expect(last_response.body).to match('NO-NAME')
        end
      end
    end

    describe 'PUT /queue/:name' do
      context 'with data' do
        it 'returns 201 CREATED' do
          post '/queues', { name: 'with-data1' }
          put '/queue/with-data1', { data: 'test-message' }
          expect(last_response.status).to eq(201)
          expect(last_response.body).to match('SUCCESS')
        end
      end

      context 'without data' do
        it 'returns 400 Bad Request' do
          post '/queues', { name: 'with-data2' }
          expect(last_response.status).to eq(201)

          put '/queue/with-data2', nil
          expect(last_response.status).to eq(400)
          expect(last_response.body).to match('NO-DATA')
        end
      end
    end

    describe 'GET /queue/:name' do
      context 'when the queue does not exist' do
        it 'returns 404 Not Found' do
          get '/queue/enoent'
          expect(last_response.status).to eq(404)
          expect(last_response.body).to match('NO-SUCH-QUEUE')
        end
      end

      context 'when the queue is empty' do
        it 'returns 204 No Content' do
          post '/queues', { name: 'empty-queue' }
          expect(last_response.status).to eq(201)

          get '/queue/empty-queue'
          expect(last_response.status).to eq(204)
        end
      end

      context 'when the queue is not empty' do
        let(:value) { 'a value' }

        it 'returns 200 OK' do
          post '/queues', { name: 'non-empty-queue' }
          expect(last_response.status).to eq(201)

          put '/queue/non-empty-queue', { data: 'a message' }
          expect(last_response.status).to eq(201)
          sleep 1

          get '/queue/non-empty-queue'
          expect(last_response.status).to eq(200)
          expect(last_response.body).to eq("a message\n")
        end
      end
    end

  end
end
