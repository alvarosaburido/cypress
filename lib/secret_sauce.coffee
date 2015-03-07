SecretSauce =
  mixin: (module, klass) ->
    for key, fn of @[module]
      klass.prototype[key] = fn

SecretSauce.Keys =
  _convertToId: (index) ->
    ival = index.toString(36)
    ## 0 pad number to ensure three digits
    [0,0,0].slice(ival.length).join("") + ival

  _getProjectKeyRange: (id) ->
    @cache.getProject(id).get("RANGE")

  ## Lookup the next Test integer and update
  ## offline location of sync
  getNextTestNumber: (projectId) ->
    @_getProjectKeyRange(projectId)
    .then (range) =>
      return @_getNewKeyRange(projectId) if range.start is range.end

      range.start += 1
      range
    .then (range) =>
      range = JSON.parse(range) if SecretSauce._.isString(range)
      @cache.updateRange(projectId, range)
      .return(range.start)

  nextKey: ->
    @project.ensureProjectId().bind(@)
    .then (projectId) ->
      @cache.ensureProject(projectId).bind(@)
      .then -> @getNextTestNumber(projectId)
      .then @_convertToId

SecretSauce.Socket =
  leadingSlashes: /^\/+/

  onTestFileChange: (filepath, stats) ->
    ## simple solution for preventing firing test:changed events
    ## when we are making modifications to our own files
    return if @app.enabled("editFileMode")

    ## return if we're not a js or coffee file.
    ## this will weed out directories as well
    return if not /\.(js|coffee)$/.test filepath

    @fs.statAsync(filepath).bind(@)
      .then ->
        ## strip out our testFolder path from the filepath, and any leading forward slashes
        filepath      = filepath.split(@app.get("cypress").projectRoot).join("").replace(@leadingSlashes, "")
        strippedPath  = filepath.replace(@app.get("cypress").testFolder, "").replace(@leadingSlashes, "")

        @io.emit "generate:ids:for:test", filepath, strippedPath
      .catch(->)

  _startListening: (chokidar, path) ->
    { _ } = SecretSauce

    @io.on "connection", (socket) =>
      console.log "socket connected"

      socket.on "generate:test:id", (data, fn) =>
        console.log("generate:test:id", data)
        @idGenerator.getId(data)
        .then(fn)
        .catch (err) ->
          console.log "\u0007", err.details, err.message
          fn(message: err.message)

      socket.on "finished:generating:ids:for:test", (strippedPath) =>
        console.log "finished:generating:ids:for:test", strippedPath
        @io.emit "test:changed", file: strippedPath

      _.each "load:iframe command:add runner:start runner:end before:run before:add after:add suite:add suite:start suite:stop test test:add test:start test:end after:run test:results:ready exclusive:test".split(" "), (event) ->
        socket.on event, (args...) =>
          args = _.chain(args).compact().reject(_.isFunction).value()
          @io.emit event, args...

      ## when we're told to run:sauce we receive
      ## the spec and callback with the name of our
      ## sauce labs job
      ## we'll embed some additional meta data into
      ## the job name
      socket.on "run:sauce", (spec, fn) =>
        ## this will be used to group jobs
        ## together for the runs related to 1
        ## spec by setting custom-data on the job object
        batchId = Date.now()

        jobName = @app.get("cypress").testFolder + "/" + spec
        fn(jobName, batchId)

        ## need to handle platform/browser/version incompatible configurations
        ## and throw our own error
        ## https://saucelabs.com/platforms/webdriver
        jobs = [
          { platform: "Windows 8.1", browser: "internet explorer",  version: 11 }
          { platform: "Windows 7",   browser: "internet explorer",  version: 10 }
          { platform: "Linux",       browser: "chrome",             version: 37 }
          { platform: "Linux",       browser: "firefox",            version: 33 }
          { platform: "OS X 10.9",   browser: "safari",             version: 7 }
        ]

        normalizeJobObject = (obj) ->
          obj = _(obj).clone()

          obj.browser = {
            "internet explorer": "ie"
          }[obj.browserName] or obj.browserName

          obj.os = obj.platform

          _(obj).pick "name", "browser", "version", "os", "batchId", "guid"

        _.each jobs, (job) =>
          options =
            host:        "0.0.0.0"
            port:        @app.get("port")
            name:        jobName
            batchId:     batchId
            guid:        uuid.v4()
            browserName: job.browser
            version:     job.version
            platform:    job.platform

          clientObj = normalizeJobObject(options)
          socket.emit "sauce:job:create", clientObj

          df = jQuery.Deferred()

          df.progress (sessionID) ->
            ## pass up the sessionID to the previous client obj by its guid
            socket.emit "sauce:job:start", clientObj.guid, sessionID

          df.fail (err) ->
            socket.emit "sauce:job:fail", clientObj.guid, err

          df.done (sessionID, runningTime, passed) ->
            socket.emit "sauce:job:done", sessionID, runningTime, passed

          sauce options, df

    testsDir = path.join(@app.get("cypress").projectRoot, @app.get("cypress").testFolder)

    @fs.ensureDirAsync(testsDir).bind(@)
      .then ->
        watchTestFiles = chokidar.watch testsDir#, ignored: (path, stats) ->

        watchTestFiles.on "change", _.bind(@onTestFileChange, @)

    ## BREAKING DUE TO __DIRNAME
    # watchCssFiles = chokidar.watch path.join(__dirname, "public", "css"), ignored: (path, stats) ->
    #   return false if fs.statSync(path).isDirectory()

    #   not /\.css$/.test path

    # # watchCssFiles.on "add", (path) -> console.log "added css:", path
    # watchCssFiles.on "change", (filepath, stats) =>
    #   filepath = path.basename(filepath)
    #   @io.emit "eclectus:css:changed", file: filepath

SecretSauce.IdGenerator =
  hasExistingId: (e) ->
    e.idFound

  idFound: ->
    e = new Error
    e.idFound = true
    throw e

  nextId: (data) ->
    @keys.nextKey().bind(@)
    .then((id) ->
      @appendTestId(data.spec, data.title, id)
      .return(id)
    )
    .catch (e) ->
      @logErr(e, data.spec)

      throw e

  appendTestId: (spec, title, id) ->
    normalizedPath = @path.join(@projectRoot, spec)

    @read(normalizedPath).bind(@)
    .then (contents) ->
      @insertId(contents, title, id)
    .then (contents) ->
      ## enable editFileMode which prevents us from sending out test:changed events
      @editFileMode(true)

      ## write the new content back to the file
      @write(normalizedPath, contents)
    .then ->
      ## remove the editFileMode so we emit file changes again
      ## if we're still in edit file mode then wait 1 second and disable it
      ## chokidar doesnt instantly see file changes so we have to wait
      @editFileMode(false, {delay: 1000})
    .catch @hasExistingId, (err) ->
      ## do nothing when the ID is existing

  insertId: (contents, title, id) ->
    re = new RegExp "['\"](" + @escapeRegExp(title) + ")['\"]"

    # ## if the string is found and it doesnt have an id
    matches = re.exec contents

    ## matches[1] will be the captured group which is the title
    return @idFound() if not matches

    ## position is the string index where we first find the capture
    ## group and include its length, so we insert right after it
    position = matches.index + matches[1].length + 1
    @str.insert contents, position, " [#{id}]"

SecretSauce.RemoteProxy =
  _handle: (req, res, next, Domain, httpProxy) ->
    ## strip out the /__remote/ from the req.url
    if not req.session.remote?
      if b = @app.get("cypress").baseUrl
        req.session.remote = b
      else
        throw new Error("™ Session Proxy not yet set! ™")

    proxy = httpProxy.createProxyServer({})

    domain = Domain.create()

    domain.on('error', next)

    domain.run =>
      @getContentStream({
        uri: req.url.split("/__remote/").join(""),
        remote: req.session.remote,
        req: req
        res: res
        proxy: proxy
      })
      .on('error', (e) -> throw e)
      .pipe(res)

  getContentStream: (opts) ->
    # console.log opts.remote, opts.uri, opts.req.url
    switch @UrlHelpers.detectScheme(opts.uri)
      when "relative" then @pipeRelativeContent(opts)
      when "absolute" then @pipeAbsoluteContent(opts)
      # when "file"     then @pipeFileContent(opts.uri, opts.res)

  pipeAbsoluteContent: (opts) ->
    remote = @url.parse(opts.uri)

    opts.req.url = opts.uri

    remote.path = "/"
    remote.pathname = "/"
    remote.query = ""
    remote.search = ""

    opts.proxy.web(opts.req, opts.res, {
      target: remote.format()
      changeOrigin: true,
      hostRewrite: opts.req.session.host
    })

    opts.res

  pipeRelativeContent: (opts) ->
    switch @UrlHelpers.detectScheme(opts.remote)
      when "relative" then @fromFile(opts)
      when "absolute" then @fromUrl(opts)

  # creates a read stream to a file stored on the users filesystem
  # taking into account if they've chosen a specific rootFolder
  # that their project files exist in
  fromFile: (opts) ->
    { _ } = SecretSauce

    ## strip off any query params from our req's url
    ## since we're pulling this from the file system
    ## it does not understand query params
    baseUri = @url.parse(opts.uri).pathname

    opts.res.contentType(@mime.lookup(baseUri))

    args = _.compact([
      @app.get("cypress").projectRoot,
      @app.get("cypress").rootFolder,
      baseUri
    ])

    @fs.createReadStream(
      @path.join(args...)
    )

  fromUrl: (opts) ->
    { _ } = SecretSauce

    @emit "verbose", "piping url content #{opts.uri}, #{opts.uri.split(opts.remote)[1]}"

    remote = @url.parse(opts.remote)

    opts.req.url = opts.req.url.replace(/\/__remote\//, "")
    opts.req.url = @url.resolve(opts.remote, opts.req.url or "")

    remote.path = "/"
    remote.pathname = "/"

    ## If the path is relative from root
    ## like foo.com/../
    ## we need to handle when it walks up past the root host and into
    ## the http:// part, so we need to fix the request url to contain
    ## the correct root.

    requestUrlBase = @url.parse(opts.req.url)
    requestUrlBase = _.extend(requestUrlBase, {
      path: "/"
      pathname: "/"
      query: ""
      search: ""
    })

    requestUrlBase = @escapeRegExp(requestUrlBase.format())

    unless (remote.format().match(///^#{requestUrlBase}///))
      basePath = @url.parse(opts.req.url).path
      basePath = basePath.replace /\/$/, ""
      opts.req.url = remote.format() + @url.parse(opts.req.url).host + basePath

    opts.proxy.web(opts.req, opts.res, {
      target: remote.format()
      changeOrigin: true,
      hostRewrite: opts.req.session.host
    })

    opts.res

  # pipeAbsoluteFileContent: (uri, res) ->
  #   @emit "verbose", "piping url content #{uri}"
  #   @pipeFileUriContents.apply(this, arguments)


  # pipeFileContent: (uri, res) ->
  #   @emit "verbose", "piping url content #{uri}"
  #   if (~uri.indexOf('file://'))
  #     uri = uri.split('file://')[1]

  #   @pipeFileUriContents.apply(this, arguments)

SecretSauce.RemoteInitial =
  _handle: (req, res, opts, Domain) ->
    { _ } = SecretSauce

    _.defaults opts,
      inject: "
        <script type='text/javascript' src='/eclectus/js/sinon.js'></script>
        <script type='text/javascript'>
          window.onerror = function(){
            parent.onerror.apply(parent, arguments)
          }
        </script>
      "

    url = @parseReqUrl(req.url)
    @Log.info "handling initial request", url: url

    ## initially set the session to this url
    ## in case we aren't grabbing url content
    ## this may later be overridden if we're
    ## going to to the web and following redirects
    @setSessionRemoteUrl(req, url)

    d = Domain.create()

    d.on 'error', (e) => @errorHandler(e, res, url)

    d.run =>
      content = @getContent(url, res, req)

      content.on "error", (e) => @errorHandler(e, res, url)

      content
      .pipe(@injectContent(opts.inject))
      .pipe(res)

  parseReqUrl: (url) ->
    ## strip out /__remote/ and the ?__initial query params
    ## and any trailing slashes
    url = new @jsUri url.split("/__remote/").join("")
    url.deleteQueryParam("__initial")
    url.toString().replace(/\/+$/, "")

  setSessionRemoteUrl: (req, url) ->
    url = url.split("?")[0].replace(/\/+$/, "")
    @Log.info "setting remote session url", url: url
    req.session.remote = url

  injectContent: (toInject) ->
    toInject ?= ""

    @through2.obj (chunk, enc, cb) ->
      src = chunk.toString()
            .replace(/<head>/, "<head> #{toInject}")

      cb(null, src)

  getContent: (url, res, req) ->
    switch scheme = @UrlHelpers.detectScheme(url)
      when "relative" then @getRelativeFileContent(url)
      when "absolute" then @getAbsoluteContent(url, res, req)
      # when "file"     then @getFileContent(url)

  getRelativeFileContent: (p) ->
    { _ } = SecretSauce

    args = _.compact([
      @app.get("cypress").projectRoot,
      # @app.get("cypress").rootFolder,
      p
    ])

    file = @path.join(args...)

    @Log.info "getting relative file content", file: file

    @fs.createReadStream(file, "utf8")

  getFileContent: (p) ->
    @fs.createReadStream(p.slice(7).split('?')[0], 'utf8')

  getAbsoluteContent: (url, res, req) ->
    @Log.info "getting absolute file content", url: url
    @_resolveRedirects(url, res, req)

  errorHandler: (e, res, url) ->
    @Log.info "error handling initial request", url: url, error: e

    filePath = @path.join(process.cwd(), "lib/html/initial_500.html")
    res.status(500).render(filePath, {
      url: url
    })

  _resolveRedirects: (url, res, req) ->
    { _ } = SecretSauce

    thr = @through((d) -> @queue(d))

    rq = @hyperquest.get url, {}, (err, incomingRes) =>
      if err?
        return thr.emit("error", err)

      if /^30(1|2|7|8)$/.test(incomingRes.statusCode)
        newUrl = @UrlHelpers.merge(url, incomingRes.headers.location)
        @Log.info "redirecting to new url", url: newUrl
        res.redirect("/__remote/" + newUrl)
      else
        if not incomingRes.headers["content-type"]
          throw new Error("Missing header: 'content-type'")
        @Log.info "received absolute file content"
        res.contentType(incomingRes.headers['content-type'])

        ## reset the session to the latest redirected URL
        @setSessionRemoteUrl(req, url)
        rq.pipe(thr)

    ## set the headers on the hyperquest request
    ## this will naturally forward cookies or auth tokens
    ## or anything else which should be proxied
    ## for some reason adding host / accept-encoding / accept-language
    ## would completely bork getbootstrap.com
    headers = _.omit(req.headers, "host", "accept-encoding", "accept-language")
    _.each headers, (val, key) ->
      rq.setHeader key, val

    thr

module?.exports = SecretSauce