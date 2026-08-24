require 'spec_helper'
require 'app'

RSpec.describe 'GET /protocols' do
  def app
    Sinatra::Application
  end

  before { ENV['VCAP_SERVICES'] = vcap_fixture('tls_off') }

  it 'reports advertised protocols as advertised' do
    get '/protocols'
    body = JSON.parse(last_response.body)
    expect(last_response.status).to eq(200)
    expect(body['amqp']['source']).to eq('advertised')
    expect(body['amqp']['port']).to eq(5672)
  end

  it 'reports derivable protocols as derived' do
    get '/protocols'
    body = JSON.parse(last_response.body)
    expect(body['mqtt']['source']).to eq('derived')
    expect(body['mqtt']['port']).to eq(1883)
  end

  it 'reports the reason for unavailable protocols' do
    get '/protocols'
    body = JSON.parse(last_response.body)
    expect(body['web_stomp_tls']['available']).to be(false)
    expect(body['web_stomp_tls']['reason']).to match(/no documented default port/)
  end

  it 'reports the url path with hyphens for every protocol' do
    get '/protocols'
    body = JSON.parse(last_response.body)
    expect(body['web_mqtt']['path']).to eq('/web-mqtt')
    expect(body['web_stomp_tls']['path']).to eq('/web-stomp-tls')
    expect(body['amqp']['path']).to eq('/amqp')
  end

  it 'never includes the password' do
    get '/protocols'
    expect(last_response.body).not_to include('app-pass')
  end
end
