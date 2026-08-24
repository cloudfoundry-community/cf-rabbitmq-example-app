require 'spec_helper'
require 'app'

RSpec.describe 'protocol-prefixed routes' do
  def app
    Sinatra::Application
  end

  let(:amqp) { instance_double(RabbitMQ::Adapters::AMQP) }

  before do
    ENV['VCAP_SERVICES'] = vcap_fixture('dual_mode')
    allow(RabbitMQ::Adapters::AMQP).to receive(:new).and_return(amqp)
  end

  it 'serves /amqp/ping' do
    allow(amqp).to receive(:ping).and_return([200, 'OK'])
    get '/amqp/ping'
    expect(last_response.status).to eq(200)
    expect(last_response.body).to eq('OK')
  end

  it 'serves /amqps/ping on the same process as /amqp/ping' do
    allow(amqp).to receive(:ping).and_return([200, 'OK'])
    get '/amqps/ping'
    expect(last_response.status).to eq(200)
  end

  it 'builds the amqps adapter from the TLS endpoint' do
    allow(amqp).to receive(:ping).and_return([200, 'OK'])
    expect(RabbitMQ::Adapters::AMQP).to receive(:new) do |endpoint|
      expect(endpoint.tls).to be(true)
      expect(endpoint.port).to eq(5671)
      amqp
    end
    get '/amqps/ping'
  end

  it 'lists queue names on GET /amqp/queues' do
    mgmt = instance_double(RabbitMQ::Adapters::Management)
    allow(RabbitMQ::Adapters::Management).to receive(:new).and_return(mgmt)
    allow(mgmt).to receive(:queue_names).and_return(%w[alpha beta])
    get '/amqp/queues'
    expect(last_response.status).to eq(200)
    expect(last_response.body).to eq("alpha\nbeta\n")
  end

  it 'declares a queue on POST /amqp/queues' do
    mgmt = instance_double(RabbitMQ::Adapters::Management)
    allow(RabbitMQ::Adapters::Management).to receive(:new).and_return(mgmt)
    allow(mgmt).to receive(:queue_exists?).with('my-queue').and_return(false)
    allow(amqp).to receive(:declare).with('my-queue').and_return([201, 'SUCCESS'])
    post '/amqp/queues', name: 'my-queue'
    expect(last_response.status).to eq(201)
    expect(last_response.body).to eq('SUCCESS')
  end

  it 'publishes on PUT /amqp/queue/:name' do
    allow(amqp).to receive(:publish).with('q', 'hello').and_return([201, 'SUCCESS'])
    put '/amqp/queue/q', data: 'hello'
    expect(last_response.status).to eq(201)
    expect(last_response.body).to eq('SUCCESS')
  end

  it 'consumes on GET /amqp/queue/:name' do
    allow(amqp).to receive(:consume).with('full').and_return([200, "a message\n"])
    get '/amqp/queue/full'
    expect(last_response.status).to eq(200)
    expect(last_response.body).to eq("a message\n")
  end

  it 'does not register a route for an unknown protocol segment' do
    get '/nonsense/ping'
    expect(last_response.status).to eq(404)
  end

  it 'returns 501 when a protocol is resolvable but has no registered adapter' do
    # Every protocol in Resolver::PROTOCOLS now has a registered adapter,
    # so this path is exercised via a stub rather than a real gap in the
    # registry - it still covers the halt(501) branch in the `adapter`
    # helper for whichever protocol a future registry omission affects.
    allow(RabbitMQ::Registry).to receive(:adapter_for).with('mqtt').and_return(nil)
    get '/mqtt/ping'
    expect(last_response.status).to eq(501)
    expect(last_response.body).to match(/NOT-SUPPORTED/)
  end

  it 'returns 503 with a reason when the protocol cannot be resolved' do
    # tls_off advertises neither amqps nor a matching amqps:// uri, so
    # amqps cannot be derived either - but it does have an adapter, so
    # this exercises the 503 path rather than the 501 path.
    ENV['VCAP_SERVICES'] = vcap_fixture('tls_off')
    get '/amqps/ping'
    expect(last_response.status).to eq(503)
    expect(last_response.body).to match(/UNAVAILABLE/)
  end

  it 'registers the hyphenated segment, not the underscored protocol key' do
    get '/web_mqtt/ping'
    expect(last_response.status).to eq(404)
    get '/web-mqtt/ping'
    expect(last_response.status).not_to eq(404)
  end
end
