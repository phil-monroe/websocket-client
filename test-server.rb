require 'tubesock'

connections = []

Thread.abort_on_exception = true

app do |env|
  puts env.inspect
  if env["HTTP_UPGRADE"] == 'websocket'
    tubesock = Tubesock.hijack(env)

    tubesock.onopen do
      tubesock.send_data "Welcome to the timeserver 3000"
      puts "open"
    end

    tubesock.onmessage do |data|
      puts "received: #{data}"
    end

    tubesock.onclose do
      connections.delete tubesock
      puts "closed"
    end

    tubesock.listen

    connections << tubesock
    [ -1, {}, [] ]
  else
    [404, {'Content-Type' => 'text/plain'}, ['Not Found']]
  end
end


Thread.new do
  loop do
    connections.each do |sock|
      sock.send_data Time.now
    end
    sleep 1
  end
end