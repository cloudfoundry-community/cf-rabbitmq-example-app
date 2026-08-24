require 'spec_helper'
require 'app'

RSpec.describe '/mgmt routes' do
  def app
    Sinatra::Application
  end

  let(:mgmt) { instance_double(RabbitMQ::Adapters::Management) }

  before do
    ENV['VCAP_SERVICES'] = vcap_fixture('tls_off')
    allow(RabbitMQ::Adapters::Management).to receive(:new).and_return(mgmt)
  end

  it 'returns the broker overview as JSON' do
    allow(mgmt).to receive(:overview).and_return('rabbitmq_version' => '3.13.7')
    get '/mgmt/ping'
    expect(last_response.status).to eq(200)
    expect(JSON.parse(last_response.body)['rabbitmq_version']).to eq('3.13.7')
  end

  it 'lists queues with their depth' do
    allow(mgmt).to receive(:queues).and_return([
      { 'name' => 'alpha', 'messages' => 3, 'consumers' => 1 }
    ])
    get '/mgmt/queues'
    body = JSON.parse(last_response.body)
    expect(body.first['name']).to eq('alpha')
    expect(body.first['messages']).to eq(3)
  end

  it 'returns a single queue' do
    allow(mgmt).to receive(:queue).with('alpha').and_return('name' => 'alpha', 'messages' => 7)
    get '/mgmt/queue/alpha'
    expect(last_response.status).to eq(200)
    expect(JSON.parse(last_response.body)['messages']).to eq(7)
  end

  it 'returns 404 for a queue the broker does not have' do
    allow(mgmt).to receive(:queue).with('nope').and_return(nil)
    get '/mgmt/queue/nope'
    expect(last_response.status).to eq(404)
    expect(last_response.body).to eq('NO-SUCH-QUEUE')
  end
end
