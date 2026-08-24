require 'spec_helper'
require 'integration_helper'
require 'app'

# Exercises the app against the real broker started by
# docker-compose.test.yml (services: rabbitmq). The binding it uses
# (integration_vcap) advertises only amqp and management - exactly what a
# real Blacksmith binding does - so every other protocol below is
# reached through the app's *derived* path, not a special-cased one.
RSpec.describe 'protocols against a live broker', :integration do
  def app
    Sinatra::Application
  end

  before { ENV['VCAP_SERVICES'] = integration_vcap }

  describe 'AMQP (advertised)' do
    it 'round-trips a message through the bare routes' do
      name = itest_queue('amqp')

      post '/queues', name: name
      expect(last_response.status).to eq(201)

      put "/queue/#{name}", data: 'hello-amqp'
      expect(last_response.status).to eq(201)

      get "/queue/#{name}"
      expect(last_response.status).to eq(200)
      expect(last_response.body).to eq("hello-amqp\n")
    end

    it 'reports 404 for a queue that does not exist' do
      get "/queue/#{itest_queue('absent')}"
      expect(last_response.status).to eq(404)
      expect(last_response.body).to eq('NO-SUCH-QUEUE')
    end
  end

  describe 'management (advertised)' do
    it 'answers /mgmt/ping with broker details' do
      get '/mgmt/ping'
      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)).to have_key('rabbitmq_version')
    end

    it 'lists the queue created by the AMQP test' do
      name = itest_queue('listed')
      post '/queues', name: name
      expect(last_response.status).to eq(201)

      get '/queues'
      expect(last_response.status).to eq(200)
      expect(last_response.body).to include(name)
    end
  end

  describe 'STOMP (derived)' do
    it 'pings over the derived endpoint' do
      get '/stomp/ping'
      expect(last_response.status).to eq(200)
      expect(last_response.body).to eq('OK')
    end

    # Before the CONNECT guard, this returned 200 OK against a broker that
    # had refused the login outright - the app certified a binding that did
    # not work. The ping example above cannot catch that: it passes either
    # way, which is exactly why this one exists.
    it 'refuses to report OK when the broker rejects the credentials' do
      bad = JSON.parse(integration_vcap)
      creds = bad['rabbitmq'][0]['credentials']
      creds['password'] = 'wrong-password'
      creds['protocols']['amqp']['password'] = 'wrong-password'
      ENV['VCAP_SERVICES'] = bad.to_json

      get '/stomp/ping'

      expect(last_response.status).to eq(502)
      expect(last_response.body).to include('CONNECT refused')
    end

    it 'round-trips a message' do
      name = itest_queue('stomp')

      post '/stomp/queues', name: name
      expect(last_response.status).to eq(201)

      put "/stomp/queue/#{name}", data: 'hello-stomp'
      expect(last_response.status).to eq(201)

      get "/stomp/queue/#{name}"
      expect(last_response.status).to eq(200)
      expect(last_response.body).to eq("hello-stomp\n")
    end
  end

  describe 'MQTT (derived)' do
    it 'pings over the derived endpoint' do
      get '/mqtt/ping'
      expect(last_response.status).to eq(200)
      expect(last_response.body).to eq('OK')
    end
  end

  describe 'WebSocket handshakes (derived)' do
    # web_mqtt/web_stomp URL segments are hyphenated at the route layer
    # (lib/routes/protocol.rb); only the protocol *keys* stay underscored.
    #
    # Previously pending against a real broker: RabbitMQ::Adapters::WebSocket#ping
    # (lib/rabbitmq/adapters/websocket.rb) used to register its :open
    # handler as `client.on(:open) { client.send(connect_frame, ...) }`.
    # The websocket-client-simple gem dispatches handlers via
    # event_emitter's #emit, which runs each listener with
    # `instance_exec` - so at handler execution time `self` was the
    # WebSocket::Client::Simple::Client, not the adapter, and
    # connect_frame (private on the adapter) was undefined on the
    # Client. Fixed by computing the frame and its type in adapter scope
    # and capturing them as locals, which instance_exec's self-rebinding
    # cannot touch. Verified against the real broker below.
    it 'completes the web-mqtt handshake' do
      get '/web-mqtt/ping'
      expect(last_response.status).to eq(200)
      expect(last_response.body).to eq('OK')
    end

    it 'completes the web-stomp handshake' do
      get '/web-stomp/ping'
      expect(last_response.status).to eq(200)
      expect(last_response.body).to eq('OK')
    end

    it 'refuses publish over web-mqtt with a pointer to the browser demo' do
      put '/web-mqtt/queue/anything', data: 'x'
      expect(last_response.status).to eq(501)
      expect(last_response.body).to include('/web-mqtt/demo')
    end

    it 'refuses publish over web-stomp with a pointer to the browser demo' do
      put '/web-stomp/queue/anything', data: 'x'
      expect(last_response.status).to eq(501)
      expect(last_response.body).to include('/web-stomp/demo')
    end
  end

  describe '/protocols' do
    it 'distinguishes advertised from derived against a binding that only advertises amqp/management' do
      get '/protocols'
      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)

      expect(body['amqp']['source']).to eq('advertised')
      expect(body['management']['source']).to eq('advertised')
      expect(body['mqtt']['source']).to eq('derived')
      expect(body['stomp']['source']).to eq('derived')
      expect(body['web_mqtt']['source']).to eq('derived')
      expect(body['web_stomp']['source']).to eq('derived')
    end
  end

  # Amendment 6: these only prove the pages and their vendored JS are
  # reachable over HTTP with the right content-type/status. Nothing here
  # (or anywhere in CI) drives a real browser, so nothing here proves
  # mqtt.connect or StompJs.Client actually run against the broker - see
  # the report for that caveat spelled out in full.
  describe 'browser demo pages (reachability only, not browser execution)' do
    it 'serves the web-mqtt demo page' do
      get '/web-mqtt/demo'
      expect(last_response.status).to eq(200)
    end

    it 'serves the web-stomp demo page' do
      get '/web-stomp/demo'
      expect(last_response.status).to eq(200)
    end

    it 'serves the vendored mqtt.js bundle' do
      get '/js/mqtt.min.js'
      expect(last_response.status).to eq(200)
    end

    it 'serves the vendored stomp.js bundle' do
      get '/js/stomp.umd.min.js'
      expect(last_response.status).to eq(200)
    end
  end
end
