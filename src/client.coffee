# Represents a user accessing the application.
class Dropbox.Client
  # Dropbox client representing an application.
  #
  # For an optimal user experience, applications should use a single client for
  # all Dropbox interactions.
  #
  # @param {Object} options the application type and API key
  # @option options {String} key the Dropbox application's key (client
  #   identifier, in OAuth2 vocabulary)
  # @option options {String} secret the Dropbox application's secret (client
  #   secret, in OAuth vocabulary); browser-side applications should not pass
  #   in a client secret
  # @option options {String} token if set, the user's access token
  # @option options {String} uid if set, the user's Dropbox UID
  constructor: (options) ->
    @apiServer = options.server or @defaultApiServer()
    @authServer = options.authServer or @defaultAuthServer()
    @fileServer = options.fileServer or @defaultFileServer()
    @downloadServer = options.downloadServer or @defaultDownloadServer()

    @onXhr = new Dropbox.Util.EventSource cancelable: true
    @onError = new Dropbox.Util.EventSource
    @onAuthStepChange = new Dropbox.Util.EventSource
    @xhrOnErrorHandler = (error, callback) => @handleXhrError error, callback

    @oauth = new Dropbox.Util.Oauth options
    @uid = options.uid or null
    @authStep = @oauth.step()
    @driver = null
    @filter = null
    @authError = null
    @_credentials = null

    @setupUrls()

  # Plugs in the OAuth / application integration code.
  #
  # @param {Dropbox.AuthDriver} driver provides the integration between the
  #   application and the Dropbox OAuth flow; most applications should be
  #   able to use one of the built-in auth drivers
  # @return {Dropbox.Client} this, for easy call chaining
  authDriver: (driver) ->
    @driver = driver
    @

  # @property {Dropbox.Util.EventSource<Dropbox.Util.Xhr>} fires cancelable
  #   events every time when a network request to the Dropbox API server is
  #   about to be sent; if the event is canceled by returning a falsey value
  #   from a listener, the network request is silently discarded; whenever
  #   possible, listeners should restrict themselves to using the xhr property
  #   of the Dropbox.Util.Xhr instance passed to them; everything else in the
  #   Dropbox.Util.Xhr API is in flux
  onXhr: null

  # @property {Dropbox.Util.EventSource<Dropbox.ApiError>} fires non-cancelable
  #   events every time when a network request to the Dropbox API server
  #   results in an error
  onError: null

  # @property {Dropbox.Util.EventSource<Dropbox.Client>} fires non-cancelable
  #   events every time this client's authStep property changes; this can be
  #   used to update UI state
  onAuthStepChange: null

  # The authenticated user's Dropbx user ID.
  #
  # This user ID is guaranteed to be consistent across API calls from the same
  # application (not across applications, though).
  #
  # @return {?String} a short ID that identifies the user, or null if no user
  #   is authenticated
  dropboxUid: ->
    @uid

  # Get the client's OAuth credentials.
  #
  # @param {?Object} the result of a prior call to credentials()
  # @return {Object} a plain object whose properties can be passed to the
  #   Dropbox.Client constructor to reuse this client's login credentials
  credentials: () ->
    @computeCredentials() unless @_credentials
    @_credentials

  # Authenticates the app's user to Dropbox' API server.
  #
  # @param {?Object} options one or more of the advanced settings below
  # @option options {Boolean} interactive if false, the authentication process
  #   will stop and call the callback whenever it would have to wait for an
  #   authorization; true by default; this is useful for determining if the
  #   authDriver has cached credentials available
  # @param {?function(?Dropbox.ApiError, Dropbox.Client)} callback called when
  #   the authentication completes; if successful, the second parameter is this
  #   client and the first parameter is null
  # @return {Dropbox.Client} this, for easy call chaining
  authenticate: (options, callback) ->
    if !callback and typeof options is 'function'
      callback = options
      options = null

    if options and 'interactive' of options
      interactive = options.interactive
    else
      interactive = true

    unless @driver or @authStep is DropboxClient.DONE
      throw new Error 'Call authDriver to set an authentication driver'

    if @authStep is DropboxClient.ERROR
      throw new Error 'Client got in an error state. Call reset() to reuse it!'


    # _fsmStep helper that transitions the FSM to the next step.
    # This is repetitive stuff done at the end of each step.
    _fsmNextStep = =>
      @authStep = @oauth.step()
      @_credentials = null
      @onAuthStepChange.dispatch @
      _fsmStep()

    # _fsmStep helper that transitions the FSM to the error step.
    _fsmErrorStep = =>
      @authStep = DropboxClient.ERROR
      @_credentials = null
      @onAuthStepChange.dispatch @
      _fsmStep()

    # Advances the authentication FSM by one step.
    oldAuthStep = null
    _fsmStep = =>
      if oldAuthStep isnt @authStep
        oldAuthStep = @authStep
        if @driver and @driver.onAuthStepChange
          @driver.onAuthStepChange(@, _fsmStep)
          return

      switch @authStep
        when DropboxClient.RESET
          # No credentials. Decide on a state param for OAuth 2 authorization.
          unless interactive
            callback null, @ if callback
            return
          if @driver.getStateParam
            @driver.getStateParam (stateParam) =>
              # NOTE: the driver might have injected the state param itself
              if @client.authStep is DropboxClient.RESET
                @oauth.setAuthStateParam stateParam
              _fsmNextStep()
          @oauth.setAuthStateParam Dropbox.Util.Oauth.randomAuthStateParam()
          _fsmNextStep()

        when DropboxClient.PARAM_SET
          # Ask the user for authorization.
          unless interactive
            callback null, @ if callback
            return
          authUrl = @authorizeUrl()
          @driver.doAuthorize authUrl, @oauth.authStateParam(), @,
              (queryParams) =>
                if queryParams.error
                  # TODO(pwnall): wrap the error around a Dropbox.ApiError
                  #               or create a Dropbox.AuthError
                  _fsmErrorStep()
                else
                  @oauth.processRedirectParams queryParams
                  @uid = queryParams.uid
                  _fsmNextStep()

        when DropboxClient.PARAM_LOADED
          # Check a previous state parameter.
          unless @driver.resumeAuthorize
            # This switches the client to the PARAM_SET state
            @oauth.setAuthStateParam @oauth.authStateParam()
            _fsmNextStep()
            return
          @driver.resumeAuthorize @oauth.authStateParam(), @, (queryParams) =>
            if queryParams.error
              # TODO(pwnall): wrap the error around a Dropbox.ApiError
              #               or create a Dropbox.AuthError
              _fsmErrorStep()
            else
              @oauth.processRedirectParams queryParams
              @uid = queryParams.uid
              _fsmNextStep()

        when DropboxClient.AUTHORIZED
          # Request token authorized, switch it for an access token.
          @getAccessToken (error, data) =>
            if error
              @authError = error
              _fsmErrorStep()
            else
              @oauth.processRedirectParams data
              @uid = data.uid
              _fsmNextStep()

        when DropboxClient.DONE  # We have an access token.
            callback null, @ if callback
            return

        when DropboxClient.SIGNED_OFF  # The user signed off, restart the flow.
          # The authStep change makes reset() not trigger onAuthStepChange.
          @authStep = DropboxClient.RESET
          @reset()
          _fsmStep()

        when DropboxClient.ERROR  # An error occurred during authentication.
          callback @authError, @ if callback
          return

    _fsmStep()  # Start up the state machine.
    @

  # @return {Boolean} true if this client is authenticated, false otherwise
  isAuthenticated: ->
    @authStep is DropboxClient.DONE

  # Revokes the user's Dropbox credentials.
  #
  # This should be called when the user explictly signs off from your
  # application, to meet the users' expectation that after they sign off, their
  # access tokens will be persisted on the machine.
  #
  # @param {?function(?Dropbox.ApiError)} callback called when
  #   the authentication completes; if successful, the error parameter is
  #   null
  # @return {XMLHttpRequest} the XHR object used for this API call
  signOut: (callback) ->
    xhr = new Dropbox.Util.Xhr 'POST', @urls.signOut
    xhr.signWithOauth @oauth
    @dispatchXhr xhr, (error) =>
      if error
        callback error if callback
        return

      # The authStep change makes reset() not trigger onAuthStepChange.
      @authStep = DropboxClient.RESET
      @reset()
      @authStep = DropboxClient.SIGNED_OFF
      @onAuthStepChange.dispatch @
      if @driver and @driver.onAuthStepChange
        @driver.onAuthStepChange @, ->
          callback error if callback
      else
        callback error if callback

  # Alias for signOut.
  signOff: (callback) ->
    @signOut callback

  # Retrieves information about the logged in user.
  #
  # @param {?Object} options the advanced settings below; for the default
  #   settings, skip the argument or pass null
  # @option options {Boolean} httpCache if true, the API request will be set to
  #   allow HTTP caching to work; by default, requests are set up to avoid
  #   CORS preflights; setting this option can make sense when making the same
  #   request repeatedly (polling?)
  # @param {function(?Dropbox.ApiError, ?Dropbox.UserInfo, ?Object)} callback
  #   called with the result of the /account/info HTTP request; if the call
  #   succeeds, the second parameter is a Dropbox.UserInfo instance, the
  #   third parameter is the parsed JSON data behind the Dropbox.UserInfo
  #   instance, and the first parameter is null
  # @return {XMLHttpRequest} the XHR object used for this API call
  getUserInfo: (options, callback) ->
    if (not callback) and (typeof options is 'function')
      callback = options
      options = null

    httpCache = false
    if options and options.httpCache
      httpCache = true

    xhr = new Dropbox.Util.Xhr 'GET', @urls.accountInfo
    xhr.signWithOauth @oauth, httpCache
    @dispatchXhr xhr, (error, userData) ->
      callback error, Dropbox.UserInfo.parse(userData), userData

  # Retrieves the contents of a file stored in Dropbox.
  #
  # Some options are silently ignored in Internet Explorer 9 and below, due to
  # insufficient support in its proprietary XDomainRequest replacement for XHR.
  # Currently, the options are: arrayBuffer, blob, length, start.
  #
  # @param {String} path the path of the file to be read, relative to the
  #   user's Dropbox or to the application's folder
  # @param {?Object} options the advanced settings below; for the default
  #   settings, skip the argument or pass null
  # @option options {String} versionTag the tag string for the desired version
  #   of the file contents; the most recent version is retrieved by default
  # @option options {String} rev alias for "versionTag" that matches the HTTP
  #   API
  # @option options {Boolean} arrayBuffer if true, the file's contents  will be
  #   passed to the callback in an ArrayBuffer; this is the recommended method
  #   of reading non-UTF8 data such as images, as it is well supported across
  #   modern browsers; requires XHR Level 2 support, which is not available in
  #   IE <= 9
  # @option options {Boolean} blob if true, the file's contents  will be
  #   passed to the callback in a Blob; this is a good method of reading
  #   non-UTF8 data, such as images; requires XHR Level 2 support, which is not
  #   available in IE <= 9
  # @option options {Boolean} buffer if true, the file's contents  will be
  #   passed to the callback in a node.js Buffer; this only works on node.js
  # @option options {Boolean} binary if true, the file will be retrieved as a
  #   binary string; the default is an UTF-8 encoded string; this relies on
  #   hacks and should not be used if the environment supports XHR Level 2 API
  # @option options {Number} length the number of bytes to be retrieved from
  #   the file; if the start option is not present, the last "length" bytes
  #   will be read; by default, the entire file is read
  # @option options {Number} start the 0-based offset of the first byte to be
  #   retrieved; if the length option is not present, the bytes between
  #   "start" and the file's end will be read; by default, the entire
  #   file is read
  # @option options {Boolean} httpCache if true, the API request will be set to
  #   allow HTTP caching to work; by default, requests are set up to avoid
  #   CORS preflights; setting this option can make sense when making the same
  #   request repeatedly (polling?)
  # @param {function(?Dropbox.ApiError, ?String, ?Dropbox.File.Stat,
  #   ?Dropbox.Http.RangeInfo)} callback called with the result of
  #   the /files (GET) HTTP request; the second parameter is the contents of
  #   the file, the third parameter is a Dropbox.File.Stat instance describing
  #   the file, and the first parameter is null; if the start and/or length
  #   options are specified, the fourth parameter describes the subset of bytes
  #   read from the file
  # @return {XMLHttpRequest} the XHR object used for this API call
  readFile: (path, options, callback) ->
    if (not callback) and (typeof options is 'function')
      callback = options
      options = null

    params = {}
    responseType = 'text'
    rangeHeader = null
    httpCache = false
    if options
      if options.versionTag
        params.rev = options.versionTag
      else if options.rev
        params.rev = options.rev

      if options.arrayBuffer
        responseType = 'arraybuffer'
      else if options.blob
        responseType = 'blob'
      else if options.buffer
        responseType = 'buffer'
      else if options.binary
        responseType = 'b'  # See the Dropbox.Util.Xhr.setResponseType docs

      if options.length
        if options.start?
          rangeStart = options.start
          rangeEnd = options.start + options.length - 1
        else
          rangeStart = ''
          rangeEnd = options.length
        rangeHeader = "bytes=#{rangeStart}-#{rangeEnd}"
      else if options.start?
        rangeHeader = "bytes=#{options.start}-"

      httpCache = true if options.httpCache

    xhr = new Dropbox.Util.Xhr 'GET',
                               "#{@urls.getFile}/#{@urlEncodePath(path)}"
    xhr.setParams(params).signWithOauth @oauth, httpCache
    xhr.setResponseType responseType
    if rangeHeader
      xhr.setHeader 'Range', rangeHeader if rangeHeader
      xhr.reportResponseHeaders()
    @dispatchXhr xhr, (error, data, metadata, headers) ->
      if headers
        rangeInfo = Dropbox.Http.RangeInfo.parse headers['content-range']
      else
        rangeInfo = null
      callback error, data, Dropbox.File.Stat.parse(metadata), rangeInfo

  # Store a file into a user's Dropbox.
  #
  # @param {String} path the path of the file to be created, relative to the
  #   user's Dropbox or to the application's folder
  # @param {String, ArrayBuffer, ArrayBufferView, Blob, File, Buffer} data the
  #   contents written to the file; if a File is passed, its name is ignored
  # @param {?Object} options the advanced settings below; for the default
  #   settings, skip the argument or pass null
  # @option options {String} lastVersionTag the identifier string for the
  #   version of the file's contents that was last read by this program, used
  #   for conflict resolution; for best results, use the versionTag attribute
  #   value from the Dropbox.File.Stat instance provided by readFile
  # @option options {String} parentRev alias for "lastVersionTag" that matches
  #   the HTTP API
  # @option options {Boolean} noOverwrite if set, the write will not overwrite
  #   a file with the same name that already exsits; instead the contents
  #   will be written to a similarly named file (e.g. "notes (1).txt"
  #   instead of "notes.txt")
  # @param {?function(?Dropbox.ApiError, ?Dropbox.File.Stat)} callback called
  #   with the result of the /files (POST) HTTP request; the second paramter is
  #   a Dropbox.File.Stat instance describing the newly created file, and the
  #   first parameter is null
  # @return {XMLHttpRequest} the XHR object used for this API call
  writeFile: (path, data, options, callback) ->
    if (not callback) and (typeof options is 'function')
      callback = options
      options = null

    useForm = Dropbox.Util.Xhr.canSendForms and typeof data is 'object'
    if useForm
      @writeFileUsingForm path, data, options, callback
    else
      @writeFileUsingPut path, data, options, callback

  # writeFile implementation that uses the POST /files API.
  #
  # @private
  # This method is more demanding in terms of CPU and browser support, but does
  # not require CORS preflight, so it always completes in 1 HTTP request.
  writeFileUsingForm: (path, data, options, callback) ->
    # Break down the path into a file/folder name and the containing folder.
    slashIndex = path.lastIndexOf '/'
    if slashIndex is -1
      fileName = path
      path = ''
    else
      fileName = path.substring slashIndex
      path = path.substring 0, slashIndex

    params = { file: fileName }
    if options
      if options.noOverwrite
        params.overwrite = 'false'
      if options.lastVersionTag
        params.parent_rev = options.lastVersionTag
      else if options.parentRev or options.parent_rev
        params.parent_rev = options.parentRev or options.parent_rev
    # TODO: locale support would edit the params here

    xhr = new Dropbox.Util.Xhr 'POST',
                               "#{@urls.postFile}/#{@urlEncodePath(path)}"
    xhr.setParams(params).signWithOauth(@oauth).setFileField('file', fileName,
        data, 'application/octet-stream')

    # NOTE: the Dropbox API docs ask us to replace the 'file' parameter after
    #       signing the request; the hack below works as intended
    delete params.file

    @dispatchXhr xhr, (error, metadata) ->
      callback error, Dropbox.File.Stat.parse(metadata) if callback

  # writeFile implementation that uses the /files_put API.
  #
  # @private
  # This method is less demanding on CPU, and makes fewer assumptions about
  # browser support, but it takes 2 HTTP requests for binary files, because it
  # needs CORS preflight.
  writeFileUsingPut: (path, data, options, callback) ->
    params = {}
    if options
      if options.noOverwrite
        params.overwrite = 'false'
      if options.lastVersionTag
        params.parent_rev = options.lastVersionTag
      else if options.parentRev or options.parent_rev
        params.parent_rev = options.parentRev or options.parent_rev
    # TODO: locale support would edit the params here
    xhr = new Dropbox.Util.Xhr 'POST',
                               "#{@urls.putFile}/#{@urlEncodePath(path)}"
    xhr.setBody(data).setParams(params).signWithOauth(@oauth)
    @dispatchXhr xhr, (error, metadata) ->
      callback error, Dropbox.File.Stat.parse(metadata) if callback

  # Atomic step in a resumable file upload.
  #
  # @param {String, ArrayBuffer, ArrayBufferView, Blob, File, Buffer} data the
  #   file contents fragment to be uploaded; if a File is passed, its name is
  #   ignored
  # @param {?Dropbox.Http.UploadCursor} cursor the cursor that tracks the
  #   state of the resumable file upload; the cursor information will not be
  #   updated when the API call completes
  # @param {function(?Dropbox.ApiError, ?Dropbox.Http.UploadCursor)} callback
  #   called with the result of the /chunked_upload HTTP request; the second
  #   paramter is a Dropbox.Http.UploadCursor instance describing the progress
  #   of the upload operation, and the first parameter is null if things go
  #   well
  # @return {XMLHttpRequest} the XHR object used for this API call
  resumableUploadStep: (data, cursor, callback) ->
    if cursor
      params = { offset: cursor.offset }
      params.upload_id = cursor.tag if cursor.tag
    else
      params = { offset: 0 }

    xhr = new Dropbox.Util.Xhr 'POST', @urls.chunkedUpload
    xhr.setBody(data).setParams(params).signWithOauth(@oauth)
    @dispatchXhr xhr, (error, cursor) ->
      if error and error.status is Dropbox.ApiError.INVALID_PARAM and
          error.response and error.response.upload_id and error.response.offset
        callback null, Dropbox.Http.UploadCursor.parse(error.response)
      else
        callback error, Dropbox.Http.UploadCursor.parse(cursor)

  # Finishes a resumable file upload.
  #
  # @param {String} path the path of the file to be created, relative to the
  #   user's Dropbox or to the application's folder
  # @param {?Object} options the advanced settings below; for the default
  #   settings, skip the argument or pass null
  # @option options {String} lastVersionTag the identifier string for the
  #   version of the file's contents that was last read by this program, used
  #   for conflict resolution; for best results, use the versionTag attribute
  #   value from the Dropbox.File.Stat instance provided by readFile
  # @option options {String} parentRev alias for "lastVersionTag" that matches
  #   the HTTP API
  # @option options {Boolean} noOverwrite if set, the write will not overwrite
  #   a file with the same name that already exsits; instead the contents
  #   will be written to a similarly named file (e.g. "notes (1).txt"
  #   instead of "notes.txt")
  # @param {?function(?Dropbox.ApiError, ?Dropbox.File.Stat)} callback called
  #   with the result of the /files (POST) HTTP request; the second paramter is
  #   a Dropbox.File.Stat instance describing the newly created file, and the
  #   first parameter is null
  # @return {XMLHttpRequest} the XHR object used for this API call
  resumableUploadFinish: (path, cursor, options, callback) ->
    if (not callback) and (typeof options is 'function')
      callback = options
      options = null

    params = { upload_id: cursor.tag }

    if options
      if options.lastVersionTag
        params.parent_rev = options.lastVersionTag
      else if options.parentRev or options.parent_rev
        params.parent_rev = options.parentRev or options.parent_rev
      if options.noOverwrite
        params.overwrite = 'false'

    # TODO: locale support would edit the params here
    xhr = new Dropbox.Util.Xhr 'POST',
        "#{@urls.commitChunkedUpload}/#{@urlEncodePath(path)}"
    xhr.setParams(params).signWithOauth(@oauth)
    @dispatchXhr xhr, (error, metadata) ->
      callback error, Dropbox.File.Stat.parse(metadata) if callback

  # Reads the metadata of a file or folder in a user's Dropbox.
  #
  # @param {String} path the path to the file or folder whose metadata will be
  #   read, relative to the user's Dropbox or to the application's folder
  # @param {?Object} options the advanced settings below; for the default
  #   settings, skip the argument or pass null
  # @option options {Number} version if set, the call will return the metadata
  #   for the given revision of the file / folder; the latest version is used
  #   by default
  # @option options {Boolean} removed if set to true, the results will include
  #   files and folders that were deleted from the user's Dropbox
  # @option options {Boolean} deleted alias for "removed" that matches the HTTP
  #   API; using this alias is not recommended, because it may cause confusion
  #   with JavaScript's delete operation
  # @option options {Boolean, Number} readDir only meaningful when stat-ing
  #   folders; if this is set, the API call will also retrieve the folder's
  #   contents, which is passed into the callback's third parameter; if this
  #   is a number, it specifies the maximum number of files and folders that
  #   should be returned; the default limit is 10,000 items; if the limit is
  #   exceeded, the call will fail with an error
  # @option options {String} versionTag used for saving bandwidth when getting
  #   a folder's contents; if this value is specified and it matches the
  #   folder's contents, the call will fail with a 304 (Contents not changed)
  #   error code; a folder's version identifier can be obtained from the
  #   versionTag attribute of a Dropbox.File.Stat instance describing it
  # @option options {Boolean} httpCache if true, the API request will be set to
  #   allow HTTP caching to work; by default, requests are set up to avoid
  #   CORS preflights; setting this option can make sense when making the same
  #   request repeatedly (polling?)
  # @param {function(?Dropbox.ApiError, ?Dropbox.File.Stat,
  #   ?Array<Dropbox.File.Stat>)} callback called with the result of the
  #   /metadata HTTP request; if the call succeeds, the second parameter is a
  #   Dropbox.File.Stat instance describing the file / folder, and the first
  #   parameter is null; if the readDir option is true and the call succeeds,
  #   the third parameter is an array of Dropbox.File.Stat instances describing
  #   the folder's entries
  # @return {XMLHttpRequest} the XHR object used for this API call
  stat: (path, options, callback) ->
    if (not callback) and (typeof options is 'function')
      callback = options
      options = null

    params = {}
    httpCache = false
    if options
      if options.version?
        params.rev = options.version
      if options.removed or options.deleted
        params.include_deleted = 'true'
      if options.readDir
        params.list = 'true'
        if options.readDir isnt true
          params.file_limit = options.readDir.toString()
      if options.cacheHash
        params.hash = options.cacheHash
      if options.httpCache
        httpCache = true
    params.include_deleted ||= 'false'
    params.list ||= 'false'
    # TODO: locale support would edit the params here
    xhr = new Dropbox.Util.Xhr 'GET',
                               "#{@urls.metadata}/#{@urlEncodePath(path)}"
    xhr.setParams(params).signWithOauth @oauth, httpCache
    @dispatchXhr xhr, (error, metadata) ->
      stat = Dropbox.File.Stat.parse metadata
      if metadata?.contents
        entries = for entry in metadata.contents
          Dropbox.File.Stat.parse(entry)
      else
        entries = undefined
      callback error, stat, entries

  # Lists the files and folders inside a folder in a user's Dropbox.
  #
  # @param {String} path the path to the folder whose contents will be
  #   retrieved, relative to the user's Dropbox or to the application's
  #   folder
  # @param {?Object} options the advanced settings below; for the default
  #   settings, skip the argument or pass null
  # @option options {Boolean} removed if set to true, the results will include
  #   files and folders that were deleted from the user's Dropbox
  # @option options {Boolean} deleted alias for "removed" that matches the HTTP
  #   API; using this alias is not recommended, because it may cause confusion
  #   with JavaScript's delete operation
  # @option options {Boolean, Number} limit the maximum number of files and
  #   folders that should be returned; the default limit is 10,000 items; if
  #   the limit is exceeded, the call will fail with an error
  # @option options {String} versionTag used for saving bandwidth; if this
  #   option is specified, and its value matches the folder's version tag,
  #   the call will fail with a 304 (Contents not changed) error code
  #   instead of returning the contents; a folder's version identifier can be
  #   obtained from the versionTag attribute of a Dropbox.File.Stat instance
  #   describing it
  # @option options {Boolean} httpCache if true, the API request will be set to
  #   allow HTTP caching to work; by default, requests are set up to avoid
  #   CORS preflights; setting this option can make sense when making the same
  #   request repeatedly (polling?)
  # @param {function(?Dropbox.ApiError, ?Array<String>, ?Dropbox.File.Stat,
  #   ?Array<Dropbox.File.Stat>)} callback called with the result of the
  #   /metadata HTTP request; if the call succeeds, the second parameter is an
  #   array containing the names of the files and folders in the given folder,
  #   the third parameter is a Dropbox.File.Stat instance describing the
  #   folder, the fourth parameter is an array of Dropbox.File.Stat instances
  #   describing the folder's entries, and the first parameter is null
  # @return {XMLHttpRequest} the XHR object used for this API call
  readdir: (path, options, callback) ->
    if (not callback) and (typeof options is 'function')
      callback = options
      options = null

    statOptions = { readDir: true }
    if options
      if options.limit?
        statOptions.readDir = options.limit
      if options.versionTag
        statOptions.versionTag = options.versionTag
      if options.removed or options.deleted
        statOptions.removed = options.removed or options.deleted
      if options.httpCache
        statOptions.httpCache = options.httpCache
    @stat path, statOptions, (error, stat, entry_stats) ->
      if entry_stats
        entries = (entry_stat.name for entry_stat in entry_stats)
      else
        entries = null
      callback error, entries, stat, entry_stats

  # Alias for "stat" that matches the HTTP API.
  metadata: (path, options, callback) ->
    @stat path, options, callback

  # Creates a publicly readable URL to a file or folder in the user's Dropbox.
  #
  # @param {String} path the path to the file or folder that will be linked to;
  #   the path is relative to the user's Dropbox or to the application's
  #   folder
  # @param {?Object} options the advanced settings below; for the default
  #   settings, skip the argument or pass null
  # @option options {Boolean} download if set, the URL will be a direct
  #   download URL, instead of the usual Dropbox preview URLs; direct
  #   download URLs are short-lived (currently 4 hours), whereas regular URLs
  #   virtually have no expiration date (currently set to 2030); no direct
  #   download URLs can be generated for directories
  # @option options {Boolean} downloadHack if set, a long-living download URL
  #   will be generated by asking for a preview URL and using the officially
  #   documented hack at https://www.dropbox.com/help/201 to turn the preview
  #   URL into a download URL
  # @option options {Boolean} long if set, the URL will not be shortened using
  #   Dropbox's shortner; the download and downloadHack options imply long
  # @option options {Boolean} longUrl synonym for long; makes life easy for
  #     RhinoJS users
  # @param {function(?Dropbox.ApiError, ?Dropbox.File.PublicUrl)} callback
  #   called with the result of the /shares or /media HTTP request; if the call
  #   succeeds, the second parameter is a Dropbox.File.PublicUrl instance, and
  #   the first parameter is null
  # @return {XMLHttpRequest} the XHR object used for this API call
  makeUrl: (path, options, callback) ->
    if (not callback) and (typeof options is 'function')
      callback = options
      options = null

    # NOTE: cannot use options.long; normally, the CoffeeScript compiler
    #       escapes keywords for us; although long isn't really a keyword, the
    #       Rhino VM thinks it is; this hack can be removed when the bug below
    #       is fixed:
    #       https://github.com/mozilla/rhino/issues/93
    if options and (options['long'] or options.longUrl or options.downloadHack)
      params = { short_url: 'false' }
    else
      params = {}

    path = @urlEncodePath path
    url = "#{@urls.shares}/#{path}"
    isDirect = false
    useDownloadHack = false
    if options
      if options.downloadHack
        isDirect = true
        useDownloadHack = true
      else if options.download
        isDirect = true
        url = "#{@urls.media}/#{path}"

    # TODO: locale support would edit the params here
    xhr = new Dropbox.Util.Xhr('POST', url).setParams(params).
                                            signWithOauth @oauth
    @dispatchXhr xhr, (error, urlData) =>
      if useDownloadHack and urlData?.url
        urlData.url = urlData.url.replace @authServer, @downloadServer
      callback error, Dropbox.File.PublicUrl.parse(urlData, isDirect)

  # Retrieves the revision history of a file in a user's Dropbox.
  #
  # @param {String} path the path to the file whose revision history will be
  #   retrieved, relative to the user's Dropbox or to the application's
  #   folder
  # @param {?Object} options the advanced settings below; for the default
  #   settings, skip the argument or pass null
  # @option options {Number} limit if specified, the call will return at most
  #   this many versions
  # @option options {Boolean} httpCache if true, the API request will be set to
  #   allow HTTP caching to work; by default, requests are set up to avoid
  #   CORS preflights; setting this option can make sense when making the same
  #   request repeatedly (polling?)
  # @param {function(?Dropbox.ApiError, ?Array<Dropbox.File.Stat>)} callback
  #   called with the result of the /revisions HTTP request; if the call
  #   succeeds, the second parameter is an array with one Dropbox.File.Stat
  #   instance per file version, and the first parameter is null
  # @return {XMLHttpRequest} the XHR object used for this API call
  history: (path, options, callback) ->
    if (not callback) and (typeof options is 'function')
      callback = options
      options = null

    params = {}
    httpCache = false
    if options
      if options.limit?
        params.rev_limit = options.limit
      if options.httpCache
        httpCache = true

    xhr = new Dropbox.Util.Xhr 'GET',
                               "#{@urls.revisions}/#{@urlEncodePath(path)}"
    xhr.setParams(params).signWithOauth @oauth, httpCache
    @dispatchXhr xhr, (error, versions) ->
      if versions
        stats = (Dropbox.File.Stat.parse(metadata) for metadata in versions)
      else
        stats = undefined
      callback error, stats

  # Alias for "history" that matches the HTTP API.
  revisions: (path, options, callback) ->
    @history path, options, callback

  # Computes a URL that generates a thumbnail for a file in the user's Dropbox.
  #
  # @param {String} path the path to the file whose thumbnail image URL will be
  #   computed, relative to the user's Dropbox or to the application's
  #   folder
  # @param {?Object} options the advanced settings below; for the default
  #   settings, skip the argument or pass null
  # @option options {Boolean} png if true, the thumbnail's image will be a PNG
  #   file; the default thumbnail format is JPEG
  # @option options {String} format value that gets passed directly to the API;
  #   this is intended for newly added formats that the API may not support;
  #   use options such as "png" when applicable
  # @option options {String} size specifies the image's dimensions; this
  #   gets passed directly to the API; currently, the following values are
  #   supported: 'small' (32x32), 'medium' (64x64), 'large' (128x128),
  #   's' (64x64), 'm' (128x128), 'l' (640x480), 'xl' (1024x768); the default
  #   value is "small"
  # @return {String} a URL to an image that can be used as the thumbnail for
  #   the given file
  thumbnailUrl: (path, options) ->
    xhr = @thumbnailXhr path, options
    xhr.paramsToUrl().url

  # Retrieves the image data of a thumbnail for a file in the user's Dropbox.
  #
  # This method is intended to be used with low-level painting APIs. Whenever
  # possible, it is easier to place the result of thumbnailUrl in a DOM
  # element, and rely on the browser to fetch the file.
  #
  # @param {String} path the path to the file whose thumbnail image URL will be
  #   computed, relative to the user's Dropbox or to the application's
  #   folder
  # @param {?Object} options the advanced settings below; for the default
  #   settings, skip the argument or pass null
  # @option options {Boolean} png if true, the thumbnail's image will be a PNG
  #   file; the default thumbnail format is JPEG
  # @option options {String} format value that gets passed directly to the API;
  #   this is intended for newly added formats that the API may not support;
  #   use options such as "png" when applicable
  # @option options {String} size specifies the image's dimensions; this
  #   gets passed directly to the API; currently, the following values are
  #   supported: 'small' (32x32), 'medium' (64x64), 'large' (128x128),
  #   's' (64x64), 'm' (128x128), 'l' (640x480), 'xl' (1024x768); the default
  #   value is "small"
  # @option options {Boolean} arrayBuffer if true, the file's contents  will be
  #   passed to the callback in an ArrayBuffer; this is the recommended method
  #   of reading thumbnails, as it is well supported across modern browsers;
  #   requires XHR Level 2 support, which is not available in IE <= 9
  # @option options {Boolean} blob if true, the file's contents  will be
  #   passed to the callback in a Blob; requires XHR Level 2 support, which is
  #   not available in IE <= 9
  # @option options {Boolean} buffer if true, the file's contents  will be
  #   passed to the callback in a node.js Buffer; this only works on node.js
  # @param {function(?Dropbox.ApiError, ?Object, ?Dropbox.File.Stat)} callback
  #   called with the result of the /thumbnails HTTP request; if the call
  #   succeeds, the second parameter is the image data as a String or Blob,
  #   the third parameter is a Dropbox.File.Stat instance describing the
  #   thumbnailed file, and the first argument is null
  # @return {XMLHttpRequest} the XHR object used for this API call
  readThumbnail: (path, options, callback) ->
    if (not callback) and (typeof options is 'function')
      callback = options
      options = null

    responseType = 'b'
    if options
      responseType = 'blob' if options.blob
      responseType = 'arraybuffer' if options.arrayBuffer
      responseType = 'buffer' if options.buffer

    xhr = @thumbnailXhr path, options
    xhr.setResponseType responseType
    @dispatchXhr xhr, (error, data, metadata) ->
      callback error, data, Dropbox.File.Stat.parse(metadata)

  # Sets up an XHR for reading a thumbnail for a file in the user's Dropbox.
  #
  # @see Dropbox.Client#thumbnailUrl
  # @return {Dropbox.Util.Xhr} an XHR request configured for fetching the
  #   thumbnail
  thumbnailXhr: (path, options) ->
    params = {}
    if options
      if options.format
        params.format = options.format
      else if options.png
        params.format = 'png'
      if options.size
        # Can we do something nicer here?
        params.size = options.size

    xhr = new Dropbox.Util.Xhr 'GET',
                               "#{@urls.thumbnails}/#{@urlEncodePath(path)}"
    xhr.setParams(params).signWithOauth(@oauth)

  # Reverts a file's contents to a previous version.
  #
  # This is an atomic, bandwidth-optimized equivalent of reading the file
  # contents at the given file version (readFile), and then using it to
  # overwrite the file (writeFile).
  #
  # @param {String} path the path to the file whose contents will be reverted
  #   to a previous version, relative to the user's Dropbox or to the
  #   application's folder
  # @param {String} versionTag the tag of the version that the file will be
  #   reverted to; maps to the "rev" parameter in the HTTP API
  # @param {?function(?Dropbox.ApiError, ?Dropbox.File.Stat)} callback called
  #   with the result of the /restore HTTP request; if the call succeeds, the
  #   second parameter is a Dropbox.File.Stat instance describing the file
  #   after the revert operation, and the first parameter is null
  # @return {XMLHttpRequest} the XHR object used for this API call
  revertFile: (path, versionTag, callback) ->
    xhr = new Dropbox.Util.Xhr 'POST',
                               "#{@urls.restore}/#{@urlEncodePath(path)}"
    xhr.setParams(rev: versionTag).signWithOauth @oauth
    @dispatchXhr xhr, (error, metadata) ->
      callback error, Dropbox.File.Stat.parse(metadata) if callback

  # Alias for "revertFile" that matches the HTTP API.
  restore: (path, versionTag, callback) ->
    @revertFile path, versionTag, callback

  # Finds files / folders whose name match a pattern, in the user's Dropbox.
  #
  # @param {String} path the path that will serve as the root of the search,
  #   relative to the user's Dropbox or to the application's folder
  # @param {String} namePattern the string that file / folder names must
  #   contain in order to match the search criteria;
  # @param {?Object} options the advanced settings below; for the default
  #   settings, skip the argument or pass null
  # @option options {Number} limit if specified, the call will return at most
  #   this many versions
  # @option options {Boolean} removed if set to true, the results will include
  #   files and folders that were deleted from the user's Dropbox; the default
  #   limit is the maximum value of 1,000
  # @option options {Boolean} deleted alias for "removed" that matches the HTTP
  #   API; using this alias is not recommended, because it may cause confusion
  #   with JavaScript's delete operation
  # @option options {Boolean} httpCache if true, the API request will be set to
  #   allow HTTP caching to work; by default, requests are set up to avoid
  #   CORS preflights; setting this option can make sense when making the same
  #   request repeatedly (polling?)
  # @param {function(?Dropbox.ApiError, ?Array<Dropbox.File.Stat>)} callback
  #   called with the result of the /search HTTP request; if the call succeeds,
  #   the second parameter is an array with one Dropbox.File.Stat instance per
  #   search result, and the first parameter is null
  # @return {XMLHttpRequest} the XHR object used for this API call
  findByName: (path, namePattern, options, callback) ->
    if (not callback) and (typeof options is 'function')
      callback = options
      options = null

    params = { query: namePattern }
    httpCache = false
    if options
      if options.limit?
        params.file_limit = options.limit
      if options.removed or options.deleted
        params.include_deleted = true
      if options.httpCache
        httpCache = true

    xhr = new Dropbox.Util.Xhr 'GET', "#{@urls.search}/#{@urlEncodePath(path)}"
    xhr.setParams(params).signWithOauth @oauth, httpCache
    @dispatchXhr xhr, (error, results) ->
      if results
        stats = (Dropbox.File.Stat.parse(metadata) for metadata in results)
      else
        stats = undefined
      callback error, stats

  # Alias for "findByName" that matches the HTTP API.
  search: (path, namePattern, options, callback) ->
    @findByName path, namePattern, options, callback

  # Creates a reference used to copy a file to another user's Dropbox.
  #
  # @param {String} path the path to the file whose contents will be
  #   referenced, relative to the uesr's Dropbox or to the application's
  #   folder
  # @param {function(?Dropbox.ApiError, ?Dropbox.File.CopyReference)} callback
  #   called with the result of the /copy_ref HTTP request; if the call
  #   succeeds, the second parameter is a Dropbox.File.CopyReference instance,
  #   and the first parameter is null
  # @return {XMLHttpRequest} the XHR object used for this API call
  makeCopyReference: (path, callback) ->
    xhr = new Dropbox.Util.Xhr 'GET',
                               "#{@urls.copyRef}/#{@urlEncodePath(path)}"
    xhr.signWithOauth @oauth
    @dispatchXhr xhr, (error, refData) ->
      callback error, Dropbox.File.CopyReference.parse(refData)

  # Alias for "makeCopyReference" that matches the HTTP API.
  copyRef: (path, callback) ->
    @makeCopyReference path, callback

  # Fetches a list of changes in the user's Dropbox since the last call.
  #
  # This method is intended to make full sync implementations easier and more
  # performant. Each call returns a cursor that can be used in a future call
  # to obtain all the changes that happened in the user's Dropbox (or
  # application directory) between the two calls.
  #
  # @param {Dropbox.Http.PulledChanges, String} cursor the result of a previous
  #   call to pullChanges, or a string containing a tag representing the
  #   Dropbox state that is used as the baseline for the change list; this
  #   should either be the Dropbox.Http.PulledChanges obtained from a previous
  #   call to pullChanges, the return value of
  #   Dropbox.Http.PulledChanges#cursor, or null / ommitted on the first call
  #   to pullChanges
  # @param {function(?Dropbox.ApiError, ?Dropbox.Http.PulledChanges)} callback
  #   called with the result of the /delta HTTP request; if the call
  #   succeeds, the second parameter is a Dropbox.Http.PulledChanges describing
  #   the changes to the user's Dropbox since the pullChanges call that
  #   produced the given cursor, and the first parameter is null
  # @return {XMLHttpRequest} the XHR object used for this API call
  pullChanges: (cursor, callback) ->
    if (not callback) and (typeof cursor is 'function')
      callback = cursor
      cursor = null

    if cursor
      if cursor.cursorTag
        params = { cursor: cursor.cursorTag }
      else
        params = { cursor: cursor }
    else
      params = {}

    xhr = new Dropbox.Util.Xhr 'POST', @urls.delta
    xhr.setParams(params).signWithOauth @oauth
    @dispatchXhr xhr, (error, deltaInfo) ->
      callback error, Dropbox.Http.PulledChanges.parse(deltaInfo)

  # Alias for "pullChanges" that matches the HTTP API.
  delta: (cursor, callback) ->
    @pullChanges cursor, callback

  # Creates a folder in a user's Dropbox.
  #
  # @param {String} path the path of the folder that will be created, relative
  #   to the user's Dropbox or to the application's folder
  # @param {?function(?Dropbox.ApiError, ?Dropbox.File.Stat)} callback called
  #   with the result of the /fileops/create_folder HTTP request; if the call
  #   succeeds, the second parameter is a Dropbox.File.Stat instance describing
  #   the newly created folder, and the first parameter is null
  # @return {XMLHttpRequest} the XHR object used for this API call
  mkdir: (path, callback) ->
    xhr = new Dropbox.Util.Xhr 'POST', @urls.fileopsCreateFolder
    xhr.setParams(root: 'auto', path: @normalizePath(path)).
        signWithOauth(@oauth)
    @dispatchXhr xhr, (error, metadata) ->
      callback error, Dropbox.File.Stat.parse(metadata) if callback

  # Removes a file or diretory from a user's Dropbox.
  #
  # @param {String} path the path of the file to be read, relative to the
  #   user's Dropbox or to the application's folder
  # @param {?function(?Dropbox.ApiError, ?Dropbox.File.Stat)} callback called
  #   with the result of the /fileops/delete HTTP request; if the call
  #   succeeds, the second parameter is a Dropbox.File.Stat instance describing
  #   the removed file or folder, and the first parameter is null
  # @return {XMLHttpRequest} the XHR object used for this API call
  remove: (path, callback) ->
    xhr = new Dropbox.Util.Xhr 'POST', @urls.fileopsDelete
    xhr.setParams(root: 'auto', path: @normalizePath(path)).
        signWithOauth(@oauth)
    @dispatchXhr xhr, (error, metadata) ->
      callback error, Dropbox.File.Stat.parse(metadata) if callback

  # node.js-friendly alias for "remove".
  unlink: (path, callback) ->
    @remove path, callback

  # Alias for "remove" that matches the HTTP API.
  delete: (path, callback) ->
    @remove path, callback

  # Copies a file or folder in the user's Dropbox.
  #
  # This method's "from" parameter can be either a path or a copy reference
  # obtained by a previous call to makeCopyRef.
  #
  # The method treats String arguments as paths and CopyReference instances as
  # copy references. The CopyReference constructor can be used to get instances
  # out of copy reference strings, or out of their JSON representations.
  #
  # @param {String, Dropbox.File.CopyReference} from the path of the file or
  #   folder that will be copied, or a Dropbox.File.CopyReference instance
  #   obtained by calling makeCopyRef or Dropbox.File.CopyReference.parse; if
  #   this is a path, it is relative to the user's Dropbox or to the
  #   application's folder
  # @param {String} toPath the path that the file or folder will have after the
  #   method call; the path is relative to the user's Dropbox or to the
  #   application folder
  # @param {?function(?Dropbox.ApiError, ?Dropbox.File.Stat)} callback called
  #   with the result of the /fileops/copy HTTP request; if the call succeeds,
  #   the second parameter is a Dropbox.File.Stat instance describing the file
  #   or folder created by the copy operation, and the first parameter is null
  # @return {XMLHttpRequest} the XHR object used for this API call
  copy: (from, toPath, callback) ->
    if (not callback) and (typeof options is 'function')
      callback = options
      options = null

    params = { root: 'auto', to_path: @normalizePath(toPath) }
    if from instanceof Dropbox.File.CopyReference
      params.from_copy_ref = from.tag
    else
      params.from_path = @normalizePath from
    # TODO: locale support would edit the params here

    xhr = new Dropbox.Util.Xhr 'POST', @urls.fileopsCopy
    xhr.setParams(params).signWithOauth @oauth
    @dispatchXhr xhr, (error, metadata) ->
      callback error, Dropbox.File.Stat.parse(metadata) if callback

  # Moves a file or folder to a different location in a user's Dropbox.
  #
  # @param {String} fromPath the path of the file or folder that will be moved,
  #   relative to the user's Dropbox or to the application's folder
  # @param {String} toPath the path that the file or folder will have after
  #   the method call; the path is relative to the user's Dropbox or to the
  #   application's folder
  # @param {?function(?Dropbox.ApiError, ?Dropbox.File.Stat)} callback called
  #   with the result of the /fileops/move HTTP request; if the call succeeds,
  #   the second parameter is a Dropbox.File.Stat instance describing the moved
  #   file or folder at its new location, and the first parameter is
  #   null
  # @return {XMLHttpRequest} the XHR object used for this API call
  move: (fromPath, toPath, callback) ->
    if (not callback) and (typeof options is 'function')
      callback = options
      options = null

    xhr = new Dropbox.Util.Xhr 'POST', @urls.fileopsMove
    xhr.setParams(
        root: 'auto', from_path: @normalizePath(fromPath),
        to_path: @normalizePath(toPath)).signWithOauth @oauth
    @dispatchXhr xhr, (error, metadata) ->
      callback error, Dropbox.File.Stat.parse(metadata) if callback

  # Removes all login information.
  #
  # @return {Dropbox.Client} this, for easy call chaining
  reset: ->
    @uid = null
    @oauth.reset()
    oldAuthStep = @authStep
    @authStep = @oauth.step()
    if oldAuthStep isnt @authStep
      @onAuthStepChange.dispatch @
    @authError = null
    @_credentials = null
    @

  # Change the client's OAuth credentials.
  #
  # @param {?Object} the result of a prior call to credentials()
  # @return {Dropbox.Client} this, for easy call chaining
  setCredentials: (credentials) ->
    oldAuthStep = @authStep
    @oauth.setCredentials credentials
    @authStep = @oauth.step()
    @uid = credentials.uid or null
    @authError = null
    @_credentials = null
    if oldAuthStep isnt @authStep
      @onAuthStepChange.dispatch @
    @

  # @return {String} a string that uniquely identifies the Dropbox application
  #   of this client
  appHash: ->
    @oauth.appHash()

  # Computes the URLs of all the Dropbox API calls.
  #
  # @private
  # This is called by the constructor, and used by the other methods. It should
  # not be used directly.
  setupUrls: ->
    @urls =
      # Authentication.
      authorize: "#{@authServer}/1/oauth2/authorize"
      token: "#{@apiServer}/1/oauth2/token"
      signOut: "#{@apiServer}/1/unlink_access_token"

      # Accounts.
      accountInfo: "#{@apiServer}/1/account/info"

      # Files and metadata.
      getFile: "#{@fileServer}/1/files/auto"
      postFile: "#{@fileServer}/1/files/auto"
      putFile: "#{@fileServer}/1/files_put/auto"
      metadata: "#{@apiServer}/1/metadata/auto"
      delta: "#{@apiServer}/1/delta"
      revisions: "#{@apiServer}/1/revisions/auto"
      restore: "#{@apiServer}/1/restore/auto"
      search: "#{@apiServer}/1/search/auto"
      shares: "#{@apiServer}/1/shares/auto"
      media: "#{@apiServer}/1/media/auto"
      copyRef: "#{@apiServer}/1/copy_ref/auto"
      thumbnails: "#{@fileServer}/1/thumbnails/auto"
      chunkedUpload: "#{@fileServer}/1/chunked_upload"
      commitChunkedUpload:
          "#{@fileServer}/1/commit_chunked_upload/auto"

      # File operations.
      fileopsCopy: "#{@apiServer}/1/fileops/copy"
      fileopsCreateFolder: "#{@apiServer}/1/fileops/create_folder"
      fileopsDelete: "#{@apiServer}/1/fileops/delete"
      fileopsMove: "#{@apiServer}/1/fileops/move"

  # @property {Number} the client's progress in the authentication process;
  #   Dropbox.Client#isAuthenticated should be called instead whenever
  #   possible; this attribute was intended to be used by OAuth drivers
  authStep: null

  # authStep value for a client that experienced an authentication error
  @ERROR: 0

  # authStep value for a properly initialized client with no user credentials
  @RESET: 1

  # authStep value for a client that has an /authorize state parameter value
  #
  # This state is entered when the state parameter is set directly by
  # Dropbox.Client#authenticate. Auth drivers that need to save the OAuth state
  # during Dropbox.AuthDriver#doAuthorize should do so in the PARAM_SET state.
  @PARAM_SET: 2

  # authStep value for a client that has an /authorize state parameter value
  #
  # This state is entered when the state parameter is loaded from an external
  # data source, by Dropbox.Client#setCredentials or
  # Dropbox.Client#constructor. Auth drivers that need to save the OAuth state
  # during Dropbox.AuthDriver#doAuthorize should check for authorization
  # completion in the PARAM_LOADED state.
  @PARAM_LOADED: 3

  # authStep value for a client that has an authorization code
  @AUTHORIZED: 4

  # authStep value for a client that has an access token
  @DONE: 5

  # authStep value for a client that voluntarily invalidated its access token
  @SIGNED_OFF: 6

  # Normalizes a Dropobx path and encodes it for inclusion in a request URL.
  #
  # @private
  # This is called internally by the other client functions, and should not be
  # used outside the {Dropbox.Client} class.
  urlEncodePath: (path) ->
    Dropbox.Util.Xhr.urlEncodeValue(@normalizePath(path)).replace /%2F/gi, '/'

  # Normalizes a Dropbox path for API requests.
  #
  # @private
  # This is an internal method. It is used by all the client methods that take
  # paths as arguments.
  #
  # @param {String} path a path
  normalizePath: (path) ->
    if path.substring(0, 1) is '/'
      i = 1
      while path.substring(i, i + 1) is '/'
        i += 1
      path.substring i
    else
      path

  # The URL for /oauth2/authorize, embedding the user's token.
  #
  # @private
  # This a low-level method called by authorize. Users should call authorize.
  #
  # @return {String} the URL that the user's browser should be redirected to in
  #   order to perform an /oauth2/authorize request
  authorizeUrl: () ->
    params = @oauth.authorizeUrlParams @driver.authType(), @driver.url()
    @urls.authorize + "?" + Dropbox.Util.Xhr.urlEncode(params)

  # Exchanges an OAuth 2 authorization code with an access token.
  #
  # @private
  # This a low-level method called by authorize. Users should call authorize.
  #
  # @param {function(error, data)} callback called with the result of the
  #   /oauth/access_token HTTP request
  getAccessToken: (callback) ->
    params = @oauth.accessTokenParams @driver.url()
    xhr = new Dropbox.Util.Xhr('POST', @urls.token).setParams(params).
        addOauthParams(@oauth)
    @dispatchXhr xhr, callback

  # Prepares and sends an XHR to the Dropbox API server.
  #
  # @private
  # This is a low-level method called by other client methods.
  #
  # @param {Dropbox.Util.Xhr} xhr wrapper for the XHR to be sent
  # @param {function(?Dropbox.ApiError, ?Object)} callback called with the
  #   outcome of the XHR
  # @return {XMLHttpRequest} the native XHR object used to make the request
  dispatchXhr: (xhr, callback) ->
    xhr.setCallback callback
    xhr.onError = @xhrOnErrorHandler
    xhr.prepare()
    nativeXhr = xhr.xhr
    if @onXhr.dispatch xhr
      xhr.send()
    nativeXhr

  # Called when an XHR issued by this client fails.
  #
  # @private
  # This is a low-level method set as the onError handler for Dropbox.Util.Xhr
  # instances set up by this client.
  #
  # @param {Dropbox.ApiError} error the XHR error
  # @param {function()} callback called when this error handler is done
  # @return {null}
  handleXhrError: (error, callback) ->
    if error.status is Dropbox.ApiError.INVALID_TOKEN and
        @authStep is DropboxClient.DONE
      # The user's token became invalid.
      @authError = error
      @authStep = DropboxClient.ERROR
      @onAuthStepChange.dispatch @
      if @driver and @driver.onAuthStepChange
        @driver.onAuthStepChange @, =>
          @onError.dispatch error
          callback error
        return null
    @onError.dispatch error
    callback error
    null

  # @private
  # @return {String} the URL to the default value for the "server" option
  defaultApiServer: ->
    'https://api.dropbox.com'

  # @private
  # @return {String} the URL to the default value for the "authServer" option
  defaultAuthServer: ->
    @apiServer.replace 'api', 'www'

  # @private
  # @return {String} the URL to the default value for the "fileServer" option
  defaultFileServer: ->
    @apiServer.replace 'api', 'api-content'

  # @private
  # @return {String} the URL to the default value for the "downloadServer"
  #   option
  defaultDownloadServer: ->
    @apiServer.replace 'api', 'dl'

  # Computes the cached value returned by credentials.
  #
  # @private
  # @see Dropbox.Client#computeCredentials
  computeCredentials: ->
    value = @oauth.credentials()
    value.uid = @uid if @uid
    if @apiServer isnt @defaultApiServer()
      value.server = @apiServer
    if @authServer isnt @defaultAuthServer()
      value.authServer = @authServer
    if @fileServer isnt @defaultFileServer()
      value.fileServer = @fileServer
    if @downloadServer isnt @defaultDownloadServer()
      value.downloadServer = @downloadServer
    @_credentials = value

DropboxClient = Dropbox.Client
