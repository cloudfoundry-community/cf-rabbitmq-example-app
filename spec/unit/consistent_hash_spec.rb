require 'spec_helper'
require 'rabbitmq/endpoint'
require 'rabbitmq/adapters/management'
require 'rabbitmq/consistent_hash'

RSpec.describe RabbitMQ::ConsistentHash do
  let(:endpoint) do
    RabbitMQ::Endpoint.new(
      protocol: 'amqp', host: 'broker.example', port: 5672, tls: false,
      username: 'u', password: 'p', vhost: 'v', source: :advertised, verify_peer: true
    )
  end
  let(:management) { instance_double(RabbitMQ::Adapters::Management) }

  subject(:demo) { described_class.new(endpoint, management) }

  it 'names its queues predictably' do
    expect(demo.queue_name(0)).to eq('consistent-hash-demo-0')
    expect(demo.queue_name(3)).to eq('consistent-hash-demo-3')
  end

  it 'uses a dedicated exchange' do
    expect(described_class::EXCHANGE_NAME).to eq('consistent-hash-demo')
  end

  it 'reports the distribution across its queues' do
    allow(management).to receive(:queues).and_return([
      { 'name' => 'consistent-hash-demo-0', 'messages' => 34 },
      { 'name' => 'consistent-hash-demo-1', 'messages' => 33 },
      { 'name' => 'consistent-hash-demo-2', 'messages' => 33 },
      { 'name' => 'unrelated-queue', 'messages' => 99 }
    ])

    expect(demo.distribution).to eq(
      'consistent-hash-demo-0' => 34,
      'consistent-hash-demo-1' => 33,
      'consistent-hash-demo-2' => 33
    )
  end

  it 'totals only its own queues' do
    allow(management).to receive(:queues).and_return([
      { 'name' => 'consistent-hash-demo-0', 'messages' => 5 },
      { 'name' => 'unrelated-queue', 'messages' => 99 }
    ])
    expect(demo.total).to eq(5)
  end

  # QUEUE_PREFIX ("consistent-hash-demo") is also the exchange name, so a
  # plain String#start_with? filter would sweep in any queue that merely
  # shares the prefix - including one this class never created, e.g. an
  # operator publishing straight to a queue named
  # "consistent-hash-demo-scratch" via the generic POST /queues route.
  # queue_name only ever emits a numeric suffix, so distribution/#total
  # are scoped to that exact shape.
  it 'does not count a same-prefixed queue this class did not create' do
    allow(management).to receive(:queues).and_return([
      { 'name' => 'consistent-hash-demo-0', 'messages' => 5 },
      { 'name' => 'consistent-hash-demo-scratch', 'messages' => 999 }
    ])

    expect(demo.distribution).to eq('consistent-hash-demo-0' => 5)
    expect(demo.total).to eq(5)
  end

  # No prior POST: the broker has no consistent-hash-demo-* queues at all.
  # #distribution/#total must report emptiness cleanly, not raise - this
  # is what backs GET /demo/consistent-hash working with no prior POST.
  it 'reports an empty distribution and zero total with no demo queues' do
    allow(management).to receive(:queues).and_return([{ 'name' => 'unrelated-queue', 'messages' => 1 }])

    expect(demo.distribution).to eq({})
    expect(demo.total).to eq(0)
  end

  # The management API can report a queue entry with no populated
  # `messages` field - e.g. a queue temporarily down or unreachable in a
  # cluster. [34, nil].sum raises TypeError; #distribution normalises to
  # 0 so #total (and the JSON the route renders) never blows up on it.
  it 'treats a queue with no messages field as zero, not a raised error' do
    allow(management).to receive(:queues).and_return([
      { 'name' => 'consistent-hash-demo-0', 'messages' => 5 },
      { 'name' => 'consistent-hash-demo-1', 'messages' => nil }
    ])

    expect(demo.distribution).to eq(
      'consistent-hash-demo-0' => 5,
      'consistent-hash-demo-1' => 0
    )
    expect(demo.total).to eq(5)
  end

  describe '#run' do
    let(:connection) { instance_double(Bunny::Session, start: nil, create_channel: channel, close: nil) }
    let(:channel) { instance_double(Bunny::Channel) }
    let(:exchange) { instance_double(Bunny::Exchange, publish: nil) }

    before { allow(Bunny).to receive(:new).and_return(connection) }

    it 'declares the exchange, binds N queues, publishes, and closes the connection' do
      allow(channel).to receive(:exchange)
        .with('consistent-hash-demo', type: 'x-consistent-hash', durable: false)
        .and_return(exchange)

      bound_queue = instance_double(Bunny::Queue)
      allow(bound_queue).to receive(:bind).with(exchange, routing_key: '1')
      allow(channel).to receive(:queue).with(anything, durable: false).and_return(bound_queue)

      result = demo.run(queues: 3, messages: 10)

      expect(result).to eq('queues' => 3, 'published' => 10)
      expect(channel).to have_received(:queue).exactly(3).times
      expect(exchange).to have_received(:publish).exactly(10).times
      expect(connection).to have_received(:close).once
    end

    # What RabbitMQ actually sends for an unrecognised exchange type is a
    # CHANNEL-level 406 PRECONDITION_FAILED - measured against 3.13.7 in
    # spec/integration/exchange_type_spec.rb, which asserts the channel
    # closes while the connection stays open.
    #
    # A connection-level 503 COMMAND_INVALID is the other plausible answer:
    # AMQP 0-9-1 classifies 503 as a hard error and Bunny maps it to
    # Bunny::CommandInvalid < Bunny::ConnectionLevelException, a sibling of
    # Bunny::ChannelLevelException rather than a subclass (see
    # session.rb#instantiate_connection_level_exception vs.
    # channel.rb#instantiate_channel_level_exception). #run translates
    # either family into PluginMissing so a broker that chooses the other
    # one is still handled.
    {
      'a channel-level close' => -> { Bunny::ChannelLevelException.new('COMMAND_INVALID - unknown exchange type', nil, nil) },
      'a connection-level close (Bunny::CommandInvalid)' => -> { Bunny::CommandInvalid.new('COMMAND_INVALID - unknown exchange type', nil, nil) }
    }.each do |description, error_factory|
      it "raises PluginMissing on #{description}, and still closes the connection" do
        allow(channel).to receive(:exchange).and_raise(error_factory.call)

        expect { demo.run(queues: 2, messages: 1) }
          .to raise_error(RabbitMQ::ConsistentHash::PluginMissing)
        expect(connection).to have_received(:close).once
      end
    end

    it 'still closes the connection when Bunny.new itself raises' do
      allow(Bunny).to receive(:new).and_raise(Bunny::TCPConnectionFailed.new('boom'))

      expect { demo.run(queues: 2, messages: 1) }.to raise_error(Bunny::TCPConnectionFailed)
      expect(connection).not_to have_received(:close)
    end
  end
end

require 'app'

RSpec.describe 'consistent-hash exchange routes' do
  def app
    Sinatra::Application
  end

  let(:mgmt) { instance_double(RabbitMQ::Adapters::Management) }
  let(:connection) { instance_double(Bunny::Session, start: nil, create_channel: channel, close: nil) }
  let(:channel) { instance_double(Bunny::Channel) }
  let(:exchange) { instance_double(Bunny::Exchange, publish: nil) }
  let(:bound_queue) { instance_double(Bunny::Queue, bind: nil) }

  before do
    ENV['VCAP_SERVICES'] = vcap_fixture('dual_mode')
    allow(RabbitMQ::Adapters::Management).to receive(:new).and_return(mgmt)
    allow(Bunny).to receive(:new).and_return(connection)
    allow(channel).to receive(:exchange).and_return(exchange)
    allow(channel).to receive(:queue).and_return(bound_queue)
  end

  describe 'POST /demo/consistent-hash' do
    it 'runs the demo and reports what it published' do
      post '/demo/consistent-hash', queues: '4', messages: '20'

      expect(last_response.status).to eq(201)
      body = JSON.parse(last_response.body)
      expect(body).to eq('queues' => 4, 'published' => 20)
      expect(channel).to have_received(:queue).exactly(4).times
      expect(exchange).to have_received(:publish).exactly(20).times
    end

    it 'defaults queues and messages when neither is given' do
      post '/demo/consistent-hash'

      expect(last_response.status).to eq(201)
      expect(JSON.parse(last_response.body)).to eq('queues' => 3, 'published' => 100)
    end

    it 'rejects a queues count below the floor' do
      post '/demo/consistent-hash', queues: '1'
      expect(last_response.status).to eq(400)
      expect(last_response.body).to eq('BAD-QUEUES')
    end

    it 'rejects a queues count above the ceiling' do
      post '/demo/consistent-hash', queues: '21'
      expect(last_response.status).to eq(400)
      expect(last_response.body).to eq('BAD-QUEUES')
    end

    it 'rejects a messages count below the floor' do
      post '/demo/consistent-hash', messages: '0'
      expect(last_response.status).to eq(400)
      expect(last_response.body).to eq('BAD-MESSAGES')
    end

    it 'rejects a messages count above the ceiling' do
      post '/demo/consistent-hash', messages: '10001'
      expect(last_response.status).to eq(400)
      expect(last_response.body).to eq('BAD-MESSAGES')
    end

    it 'accepts the inclusive floor of both bounds' do
      post '/demo/consistent-hash', queues: '2', messages: '1'
      expect(last_response.status).to eq(201)
      expect(JSON.parse(last_response.body)).to eq('queues' => 2, 'published' => 1)
    end

    it 'accepts the inclusive ceiling of both bounds' do
      post '/demo/consistent-hash', queues: '20', messages: '10000'
      expect(last_response.status).to eq(201)
      expect(JSON.parse(last_response.body)).to eq('queues' => 20, 'published' => 10_000)
    end

    # Amendment 3: an unknown exchange type is a clear, named failure -
    # not the catch-all handler's opaque "ERR:..." 500. Parameterised over
    # both exception families Bunny can raise for it (see the #run specs
    # above for why) so this doesn't just prove the rescue clause matches
    # the class the test itself picked.
    {
      'a channel-level close' => -> { Bunny::ChannelLevelException.new('COMMAND_INVALID - unknown exchange type', nil, nil) },
      'a connection-level close (Bunny::CommandInvalid)' => -> { Bunny::CommandInvalid.new('COMMAND_INVALID - unknown exchange type', nil, nil) }
    }.each do |description, error_factory|
      it "reports 501 naming the plugin on #{description}" do
        allow(channel).to receive(:exchange).and_raise(error_factory.call)

        post '/demo/consistent-hash'

        expect(last_response.status).to eq(501)
        expect(last_response.body).to include('rabbitmq_consistent_hash_exchange')
      end
    end

    # Amendment 1: this demo is AMQP-only. A viewer's protocol selection
    # (query param or cookie) must not steer it onto anything else, even
    # when the selection resolves fine on its own.
    it 'runs over AMQP even when the viewer has selected a different protocol' do
      post '/demo/consistent-hash?protocol=amqps'

      expect(last_response.status).to eq(201)
      expect(Bunny).to have_received(:new) do |**opts|
        expect(opts[:port]).to eq(5672)
        expect(opts[:tls]).to be(false)
      end
    end
  end

  describe 'GET /demo/consistent-hash' do
    it 'reports an empty distribution with no prior POST, rather than 404 or 500' do
      allow(mgmt).to receive(:queues).and_return([])

      get '/demo/consistent-hash'

      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)).to eq('distribution' => {}, 'total' => 0)
    end

    it 'reports the live spread once messages have been published' do
      allow(mgmt).to receive(:queues).and_return([
        { 'name' => 'consistent-hash-demo-0', 'messages' => 12 },
        { 'name' => 'consistent-hash-demo-1', 'messages' => 8 }
      ])

      get '/demo/consistent-hash'

      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)).to eq(
        'distribution' => { 'consistent-hash-demo-0' => 12, 'consistent-hash-demo-1' => 8 },
        'total' => 20
      )
    end
  end
end
