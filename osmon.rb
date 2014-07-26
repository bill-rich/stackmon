#!/usr/bin/ruby2.1.2

require 'net/http'
require 'json'

def parseConfig()
	config = Hash.new
	File.open("/etc/stackmon.conf").each do |line|
		(key, value) = line.chomp.gsub(/\'|\"|\s/,'').split(/=/)
		config[key] = value
	end
	return config
end
def authenticate(config)
	post_data = {
		'auth' => {
			'tenantName' => config["OS_TENANT_NAME"],
			'passwordCredentials' => {
				'username' => config["OS_USERNAME"],
				'password' => config["OS_PASSWORD"]
			}
		}
	}.to_json

	url = config['OS_AUTH_URL'] + "/tokens"

	keystone_raw = JSON.parse httpPost(url, post_data, {'Content-Type' => 'application/json'}).body
	token = keystone_raw["access"]["token"]["id"]
	service_catalog = Hash.new
	keystone_raw["access"]["serviceCatalog"].each do |service|
		type = service['type']
		url = service['endpoints'].first['publicURL']
		service_catalog[type] = url
	end
	return [token, service_catalog]
end

def httpPost(url, data, headers)
	uri=URI(url)
	req = Net::HTTP::Post.new(uri)
	headers.each do |key,value|
		req[key] = value
	end
	req.body = data
	res = Net::HTTP.start(uri.hostname, uri.port) do |http|
		http.request(req)
	end
	return res
end

def httpDelete(url, headers)
	uri=URI(url)
	req = Net::HTTP::Delete.new(uri)
	headers.each do |key,value|
		req[key] = value
	end
	res = Net::HTTP.start(uri.hostname, uri.port) do |http|
		http.request(req)
	end
	return res
end

def httpGet(url, headers)
	uri=URI(url)
	req = Net::HTTP::Get.new(uri)
	headers.each do |key,value|
		req[key] = value
	end
	res = Net::HTTP.start(uri.hostname, uri.port) do |http|
		http.request(req)
	end
	return res
end

def deleteServer(token, service_catalog, uuid)
	url = service_catalog['compute'] + '/servers/' + uuid
	httpDelete(url, {'Content-Type' => 'application/json', 'X-Auth-Token' => token}).body
	return true
end

def getServer(token, service_catalog, uuid)
	url = service_catalog['compute'] + '/servers/' + uuid
	nova_raw = JSON.parse httpGet(url, {'Content-Type' => 'application/json', 'X-Auth-Token' => token}).body
	return nova_raw
end

def listServers(token, service_catalog)
	url = service_catalog['compute'] + '/servers'
	nova_raw = JSON.parse httpGet(url, {'Content-Type' => 'application/json', 'X-Auth-Token' => token}).body
	return nova_raw
end

def createServer(token, service_catalog, name, image, flavor, az, network)
	url = service_catalog['compute'] + '/servers'
	post_data = {
		'server' => {
			'name' => name,
			'imageRef' => image,
			'flavorRef' => flavor,
			'availability_zone' => az,
			'networks' => [{
				'uuid' => network
			}]
		}
	}.to_json
	nova_raw = JSON.parse httpPost(url, post_data, {'Content-Type' => 'application/json', 'X-Auth-Token' => token}).body
	return nova_raw
end

def suiteCheck(config)
	(token, service_catalog) = authenticate(config)
	test_server = createServer(token, service_catalog, 'billapi', '265d0087-9377-49b3-b51f-29969dd9dccf', '2', '', '0b0fb677-818d-43d5-bb64-59e4a1d709c3')
	while getServer(token, service_catalog, test_server['server']['id'])['server']['status'] != "ACTIVE" do
		sleep 5
	end
	deleteServer(token, service_catalog, test_server['server']['id'])
end

suite_check_time = 0
service_check_time = 0
config = parseConfig
service_ok=1
suite_ok=1
loop do
	now = Time.now().to_i
	if now - suite_check_time >= 1800
		begin
			suiteCheck(config)
			suite_ok=1
		rescue
			suite_ok=0
		end
		suite_check_time=now
	end

	if now - service_check_time >= 60
		begin
			(token, service_catalog) = authenticate(config)
			listServers(token, service_catalog)
			service_ok=1
		rescue
			service_ok=0
		end
		service_check_time=now
	end

	puts "PUTVAL #{config['HOSTNAME']}/openstack_check/gauge-suite_ok" +" interval=20 #{now}:#{suite_ok}\n"
	puts "PUTVAL #{config['HOSTNAME']}/openstack_check/gauge-service_ok" +" interval=20 #{now}:#{service_ok}\n"
	STDOUT.flush
	sleep 20
end
