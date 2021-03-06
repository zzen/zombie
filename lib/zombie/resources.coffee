# Resources loaded by a window.
#
# Each Window has a `resources` object that records resources (page,
# JavaScript, XHR requests, etc) loaded by the document.  This provides
# a request/response trail you can inspect when troubleshooting the
# page.  The resources list is cleared each time the window reloads.
#
# If you're familiar with the WebKit Inspector Resources pane, this does
# the same thing.

inspect = require("util").inspect
HTTP = require("http")
HTTPS = require("https")
FS = require("fs")
Path = require("path")
QS = require("querystring")
URL = require("url")


partial = (text, length = 250)->
  return "" unless text
  return text if text.length <= length
  return text.substring(0, length - 3) + "..."
indent = (text)->
  text.toString().split("\n").map((l)-> "  #{l}").join("\n")


# Represents a resource loaded by the window.  You can use this to peer
# into requests made by the browser, from resources linked to the
# document, XHR requests, etc.
#
# Each resource consists of:
# - elapsed -- Time took to complete the response in milliseconds
# - request -- Represents the request, see HTTPRequest
# - response -- Represents the response, see HTTPResponse
# - size -- Response size in bytes
# - url -- Resource URL
class Resource
  constructor: (@request)->
    @request.resource = this
    @redirects = 0
    @start = new Date().getTime()
    @time = 0
  @prototype.__defineGetter__ "size", ->
    return @response?.body.length || 0
  @prototype.__defineGetter__ "url", ->
    return @response?.url || @request.url
  @prototype.__defineGetter__ "response", ->
    return @_response
  @prototype.__defineSetter__ "response", (response)->
    @time = new Date().getTime() - @start
    response.resource = this
    @_response = response
  toString: ->
    return "URL:      #{@url}\nTime:     #{@time}ms\nSize:     #{@size / 1024}kb\nRequest:\n#{indent @request}\nResponse:\n#{indent @response}\n"


# Represents a request.  You can get all past requests from the
# resource list.
#
# Each request has:
# - body -- Document body (empty for GET and HEAD)
# - headers -- All headers passed to the server
# - method -- HTTP method name
# - resource -- Reference to the Resource object
# - url -- Full request URL
class HTTPRequest
  constructor: (@method, url, @headers, @body)->
    @url = URL.format(url)
  toString: ->
    return "#{inspect @headers}\n#{partial @body}"


# Represents a response.  You can get all past requests from the
# resource list.  This object is also passed to the callback with all
# the information you will need to process the response.
#
# Each response has:
# - body -- Document body
# - headers -- All headers returned from the server
# - redirected -- True if redirected before processing response
# - resource -- Reference to the Resource object
# - statusCode -- Status code returned from the server
# - statusText -- Text string associated with status code
# - url -- URL of the resource (after redirect)
class HTTPResponse
  constructor: (url, @statusCode, @headers, @body)->
    @url = URL.format(url)
  @prototype.__defineGetter__ "statusText", ->
    return STATUS[@statusCode]
  @prototype.__defineGetter__ "redirected", ->
    return !!@resource.redirects
  toString: ->
    return "#{@statusCode} #{@statusText}\n#{inspect @headers}\n#{partial @body}"


# The resources list is essentially an array, and new resources
# (Resource objects) are added as they are loaded.  The array also
# supports the `request` method and the shorthand `get`.
class Resources extends Array
  constructor: (@_browser)->
  # Returns the first resource in this array (the page loaded by this
  # window).
  @prototype.__defineGetter__ "first", ->
    return this[0]

  # Returns the last resource in this array.
  @prototype.__defineGetter__ "last", ->
    return this[@length - 1]

  # Makes a GET request.  See `request` for more details about
  # callback and response object.
  get: (url, callback)->
    @request "GET", url, null, null, callback

  # Makes a request.  Requires HTTP method and resource URL.
  #
  # Optional data object is used to construct query string parameters
  # or request body (e.g submitting a form).
  #
  # Optional headers are passed to the server.  When making a POST/PUT
  # request, you probably want specify the `content-type` header.
  #
  # The callback is called with error and response (see `HTTPResponse`).
  request: (method, url, data, headers, callback)->
    @_browser._eventloop.perform (done)=>
      @_makeRequest method, url, data, headers, null, (error, response)->
        done()
        callback error, response

  clear: ->
    @length = 0

  # Dump all resources to the console by calling toString.
  dump: ->
    console.log this.toString()

  toString: ->
    @map((resource)-> resource.toString()).join("\n")

  # Implementation of the request method, which also accepts the
  # resource.  Initially the resource is null, but when following a
  # redirect this function is called again with a resource and
  # modifies it instead of recording a new one.
  _makeRequest: (method, url, data, headers, resource, callback)->
    url = URL.parse(url)
    method = (method || "GET").toUpperCase()

    # If the request is for a file:// descriptor, just open directly from the
    # file system rather than getting node's http (which handles file://
    # poorly) involved.
    if url.protocol == "file:"
      @_browser.log -> "#{method} #{url.pathname}"
      if method == "GET"
        FS.readFile Path.normalize(url.pathname), (err, data) =>
          # Fallback with error -> callback
          if err
            @_browser.log -> "Error loading #{URL.format(url)}: #{err.message}"
            callback err
          # Turn body from string into a String, so we can add property getters.
          response = new HTTPResponse(url, 200, {}, String(data))
          callback null, response
      else
        callback new Error("Cannot #{method} a file: URL")
      return

    # Clone headers before we go and modify them.
    headers = if headers then JSON.parse(JSON.stringify(headers)) else {}
    headers["Accept-Encoding"] = @_browser.acceptEncoding
    headers["User-Agent"] = @_browser.userAgent
    if method == "GET" || method == "HEAD"
      # Request paramters go in query string
      url.search = "?" + stringify(data) if data
    else
      # Construct body from request parameters.
      switch headers["content-type"]
        when "multipart/form-data"
          if Object.keys(data).length > 0
            boundary = "#{new Date().getTime()}#{Math.random()}"
            headers["content-type"] += "; boundary=#{boundary}"
          else
            headers["content-type"] = "text/plain;charset=UTF-8"
        when "application/x-www-form-urlencoded"
          data = stringify(data)
          unless headers["transfer-encoding"]
            headers["content-length"] ||= data.length
        else
          # Fallback on sending text. (XHR falls-back on this)
          headers["content-type"] ||= "text/plain;charset=UTF-8"

    # Pre 0.3 we need to specify the host name.
    headers["Host"] = url.host
    url.pathname = "/#{url.pathname || ""}" unless url.pathname && url.pathname[0] == "/"
    url.hash = null
    # We're going to use cookies later when recieving response.
    cookies = @_browser.cookies(url.hostname, url.pathname)
    cookies.addHeader headers
    # Pathname for HTTP request needs to start with / and include query
    # string.
    secure = url.protocol == "https:"
    url.port ||= if secure then 443 else 80

    # First request has not resource, so create it and add to
    # Resources.  After redirect, we have a resource we're using.
    unless resource
      resource = new Resource(new HTTPRequest(method, url, headers, null))
      this.push resource
    @_browser.log -> "#{method} #{URL.format(url)}"

    request =
      host: url.hostname
      port: url.port
      path: "#{url.pathname}#{url.search || ""}"
      method: method
      headers: headers
    response_handler = (response)=>
      response.setEncoding "utf8"
      body = ""
      response.on "data", (chunk)-> body += chunk
      response.on "end", =>
        cookies.update response.headers["set-cookie"]

        # Turn body from string into a String, so we can add property getters.
        resource.response = new HTTPResponse(url, response.statusCode, response.headers, body)

        error = null
        switch response.statusCode
          when 301, 302, 303, 307
            if response.headers["location"]
              redirect = URL.resolve(URL.format(url), response.headers["location"])
              @_browser.log -> "#{method} #{url.pathname} => #{redirect}"
              # Fail after fifth attempt to redirect, better than looping forever
              if (resource.redirects += 1) > 5
                error = new Error("Too many redirects, from #{URL.format(url)} to #{redirect}")
              else
                process.nextTick =>
                  @_makeRequest "GET", redirect, null, headers, resource, callback
            else
              error = new Error("Redirect with no Location header, cannot follow")
          else
            @_browser.log -> "#{method} #{URL.format(url)} => #{response.statusCode}"
            callback null, resource.response
        # Fallback with error -> callback
        if error
          @_browser.log -> "Error loading #{URL.format(url)}: #{error.message}"
          error.response = resource.response
          resource.error = error
          callback error
    
    client = (if secure then HTTPS else HTTP).request(request, response_handler)
    # Connection error wired directly to callback.
    client.on "error", (error)=>
      @_browser.log -> "#{method} #{URL.format(url)} => #{error.message}"
      callback error

    if method == "PUT" || method == "POST"
      # Construct body from request parameters.
      switch headers["content-type"].split(";")[0]
        when "application/x-www-form-urlencoded"
          client.write data, "utf8"
        when "multipart/form-data"
          remaining = Object.keys(data).length
          if remaining > 0
            boundary = headers["content-type"].match(/boundary=(.*)/)[1]
            for field in data
              [name, content] = field
              client.write "--#{boundary}\r\n"
              disp = "Content-Disposition: form-data; name=\"#{name}\""
              if content.read
                disp += "; filename=\"#{content}\""
                mime = content.mime || "application/octet-stream"
              else
                mime = "text/plain"

              client.write "#{disp}\r\n"
              client.write "Content-Type: #{mime}\r\n"
              if content.read
                buffer = content.read()
                client.write "Content-Length: #{buffer.length}\r\n"
                client.write "\r\n"
                client.write buffer
              else
                client.write "Content-Length: #{content.length}\r\n"
                client.write "Content-Transfer-Encoding: utf8\r\n\r\n"
                client.write content, "utf8"
              if --remaining == 0
                client.write "\r\n--#{boundary}--\r\n"
              else
                client.write "\r\n--#{boundary}\r\n"
        else
          client.write (data || "").toString(), "utf8"
    client.end()

  typeOf = (object)->
    return Object.prototype.toString.call(object)

  # We use this to convert data array/hash into application/x-www-form-urlencoded
  stringifyPrimitive = (v)->
    switch typeOf(v)
      when '[object Boolean]' then v ? 'true' : 'false'
      when '[object Number]'  then isFinite(v) ? v : ''
      when '[object String]'  then v
      else ''

  stringify = (object)->
    return object.toString() unless object.map
    object.map((k) ->
      if Array.isArray(k[1])
        k[1].map((v) ->
          QS.escape(stringifyPrimitive(k[0])) + "=" + QS.escape(stringifyPrimitive(v))
        ).join("&")
      else
        QS.escape(stringifyPrimitive(k[0])) + "=" + QS.escape(stringifyPrimitive(k[1]))
    ).join("&")


class Cache
  constructor: (browser)->
    @resources = browser.resources

  # Makes a GET request using the cache.  See `request` for more
  # details about callback and response object.
  get: (url, callback)->
    @request "GET", url, null, null, callback

  request: (method, url, data, headers, callback)->
    @resources.request method, url, data, headers, callback


# HTTP status code to status text
STATUS =
  100: "Continue"
  101: "Switching Protocols"
  200: "OK"
  201: "Created"
  202: "Accepted"
  203: "Non-Authoritative"
  204: "No Content"
  205: "Reset Content"
  206: "Partial Content"
  300: "Multiple Choices"
  301: "Moved Permanently"
  302: "Found"
  303: "See Other"
  304: "Not Modified"
  305: "Use Proxy"
  307: "Temporary Redirect"
  400: "Bad Request"
  401: "Unauthorized"
  402: "Payment Required"
  403: "Forbidden"
  404: "Not Found"
  405: "Method Not Allowed"
  406: "Not Acceptable"
  407: "Proxy Authentication Required"
  408: "Request Timeout"
  409: "Conflict"
  410: "Gone"
  411: "Length Required"
  412: "Precondition Failed"
  413: "Request Entity Too Large"
  414: "Request-URI Too Long"
  415: "Unsupported Media Type"
  416: "Requested Range Not Satisfiable"
  417: "Expectation Failed"
  500: "Internal Server Error"
  501: "Not Implemented"
  502: "Bad Gateway"
  503: "Service Unavailable"
  504: "Gateway Timeout"
  505: "HTTP Version Not Supported"


module.exports = Resources
