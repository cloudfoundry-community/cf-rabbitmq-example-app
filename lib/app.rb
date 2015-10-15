require 'sinatra'
require 'bunny'
require 'cf-app-utils'

DATA ||= {}

before do
  unless rabbitmq_url
    halt 500, %{You must bind a RabbitMQ service instance to this application.

You can run the following commands to create an instance and bind to it:

  $ cf create-service p-rabbitmq development rabbitmq-instance
  $ cf bind-service <app-name> rabbitmq-instance}
  end
end

get '/ping' do
  begin
    c = Bunny.new(rabbitmq_url)
    c.start
    c.create_channel

    status 200
    body 'OK'

  rescue Exception => e
    halt 500, "ERR:#{e}"
  end
end

get '/env' do
  status 200
  body "rabbitmq_url: #{rabbitmq_url}\n"
end

get '/queues' do
  status 200
  body DATA.keys.map { |q| "#{q}\n" }.join
end

post '/queues' do
  unless params[:name]
    halt 400, 'NO-NAME'
  end

  q = mq(params[:name])
  if DATA.has_key?(q)
    halt 304, 'EXISTS'
  end

  DATA[q] = []
  queue(q).subscribe(
    :manual_ack  => true,
    :timeout     => 10,
    :message_max => 1
  ) do |delivery, props, payload|
    DATA[q].push payload
  end

  status 201
  body 'SUCCESS'
end

put '/queue/:name' do
  q = mq(params[:name])

  if params[:data]
    if !DATA.has_key?(q)
      status 404
      body 'NO-SUCH-QUEUE'

    else
      exchange.publish(params[:data],
        :content_type => 'text/plain',
        :key => mq(params[:name]))

      status 201
      body 'SUCCESS'
    end
  else
    status 400
    body 'NO-DATA'
  end
end

get '/queue/:name' do
  q = mq(params[:name])

  halt 404, 'NO-SUCH-QUEUE' unless DATA.has_key?(q)
  halt 204                      if DATA[q].empty?

  status 200
  lst = DATA[q]
  DATA[q] = []
  body lst.map { |m| "#{m}\n" }.join
end

error do
  halt 500, "ERR:#{env['sinatra.error']}"
end

#############################################

def mq(name)
  "test.mq.#{name}"
end

def rabbitmq_url
  return nil unless ENV['VCAP_SERVICES']

  JSON.parse(ENV['VCAP_SERVICES'], :symbolize_names => true).values.map do |services|
    services.each do |s|
      begin
        return s[:credentials][:uri]
      rescue Exception
      end
    end
  end
  nil
end

def client
  unless $client
    begin
      c = Bunny.new(rabbitmq_url)
      c.start
      $client = c.create_channel
    rescue Exception
    end
  end
  $client
end

def queue(name)
  $queues ||= {}
  $queues[name] ||= client.queue(name)
end

def exchange
  @exchange ||= client.exchange('')
end
