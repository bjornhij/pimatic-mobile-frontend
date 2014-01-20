module.exports = (env) ->

  # ##Dependencies
  # * from node.js
  util = require 'util'
  fs = require 'fs'
  path = require 'path'

  # * pimatic imports.
  convict = env.require "convict"
  Q = env.require 'q'
  assert = env.require 'cassert'
  express = env.require "express" 
  coffee = env.require 'coffee-script'

  global.i18n = env.require('i18n')
  global.__ = i18n.__
  _ = env.require 'lodash'

  # * own
  socketIo = require 'socket.io'
  global.nap = require 'nap'

  # ##The MobileFrontend
  class MobileFrontend extends env.plugins.Plugin
    pluginDependencies: ['rest-api']
    additionalAssetFiles:
      'js': []
      'css': []
      'html': []
    assetsPacked: no


    # ###init the frontend:
    init: (@app, @framework, @jsonConfig) ->
      conf = convict require("./mobile-frontend-config-shema")
      conf.load jsonConfig
      conf.validate()
      @config = conf.get ""

      # do some legacy support
      for item in @config.items
        if item.type is 'actuator' or item.type is 'sensor'
          item.type = 'device'

        
      # * Delivers json-Data in the form of:

      # 
      #     {
      #       "items": [
      #         { "id": "light",
      #           "name": "Schreibtischlampe",
      #           "state": null },
      #           ...
      #       ], "rules": [
      #         { "id": "printerOff",
      #           "condition": "its 6pm",
      #           "action": "turn the printer off" },
      #           ...
      #       ]
      #     }
      # 
      app.get '/data.json', (req, res) =>
        @getItemsWithData().then( (items) =>
          rules = []
          for id of framework.ruleManager.rules
            rule = framework.ruleManager.rules[id]
            rules.push
              id: id
              condition: rule.orgCondition
              action: rule.action
              active: rule.active
              valid: rule.valid
              error: rule.error
          res.send 
            errorCount: env.logger.transports.memory.getErrorCount()
            items: items
            rules: rules
        ).done()
    
      app.get '/add-device/:deviceId', (req, res) =>
        deviceId = req.params.deviceId
        if not deviceId?
          return res.send 200, {success: false, message: 'no id given'}
        found = false
        for item in @config.items
          if item.type is 'device' and item.id is deviceId
            found = true
            break
        if found 
          res.send 200, {success: false, message: 'device already added'}
          return

        item = 
          type: 'device'
          id: deviceId

        @addNewItem item
        res.send 200, {success: true}
    
    
      app.get '/add-header/:name', (req, res) =>
        name = req.params.name
        if not acutatorId? or name is ""
          res.send 200, {success: false, message: 'no name given'}
        item = 
          type: 'header'
          id: "header-#{name}"
          text: name

        @addNewItem item
        res.send 200, {success: true}
    
      app.post '/update-order', (req, res) =>
        order = req.body.order
        unless order?
          res.send 200, {success: false, message: 'no order given'}
          return
        newItems = []
        for orderItem in order
          assert orderItem.type?
          assert orderItem.id?
          for item in jsonConfig.items
            if item.id is orderItem.id and item.type is orderItem.type
              newItems.push item
              break
        if not (newItems.length is jsonConfig.items.length)
          res.send 200, {success: false, message: 'items do not equal, reject order'}
          return
        @config.items = @jsonConfig.items = newItems
        @framework.saveConfig()
        res.send 200, {success: true}
    
      app.get '/clear-log', (req, res) =>
        env.logger.transports.memory.clearLog()
        res.send 200, {success: true}
    
      app.post '/remove-item', (req, res) =>
        item = req.body.item
        unless item?
          res.send 200, {success: false, message: 'no item given'}
          return
        for it, i in jsonConfig.items
          if it.id is item.id and it.type is item.type
            jsonConfig.items.splice i, 1
            break
    
        @config.items = @jsonConfig.items
        @framework.saveConfig()

        res.send 200, {success: true}
    
      # * Static assets
      app.use express.static(__dirname + "/public")

      # ###Socket.io stuff:
      # For every webserver
      for webServer in [app.httpServer, app.httpsServer]
        continue unless webServer?
        # Listen for new websocket connections
        io = socketIo.listen webServer, {
          logger: 
            log: (type, args...) ->
              if type isnt 'debug' then env.logger.log(type, 'socket.io:', args...)
            debug: (args...) -> this.log('debug', args...)
            info: (args...) -> this.log('info', args...)
            warn: (args...) -> this.log('warn', args...)
            error: (args...) -> this.log('error', args...)
        }

        # When a new client connects
        io.sockets.on 'connection', (socket) =>

          for item in @config.items 
            do (item) =>
              switch item.type
                when "device" 
                  @addAttributeNotify socket, item

          env.logger.debug("adding rule listerns") if @config.debug
          framework.ruleManager.on "add", addRuleListener = (rule) =>
            @emitRuleUpdate socket, "add", rule
          
          framework.ruleManager.on "update", updateRuleListener = (rule) =>
            @emitRuleUpdate socket, "update", rule
         
          framework.ruleManager.on "remove", removeRuleListener = (rule) =>
            @emitRuleUpdate socket, "remove", rule

          env.logger.debug("adding log listern") if @config.debug
          memoryTransport = env.logger.transports.memory
          memoryTransport.on 'log', logListener = (entry)=>
            socket.emit 'log', entry

          env.logger.debug("adding item-add listern") if @config.debug
          @on 'item-add', addItemListener = (item) =>
            @addAttributeNotify socket, item
            socket.emit "item-add", item

          socket.on 'disconnect', => 
            env.logger.debug("removing rule listerns") if @config.debug
            framework.ruleManager.removeListener "update", updateRuleListener
            framework.ruleManager.removeListener "add", addRuleListener 
            framework.ruleManager.removeListener "update", removeRuleListener
            env.logger.debug("removing log listern") if @config.debug
            memoryTransport.removeListener 'log', logListener
            env.logger.debug("removing item-add listerns") if @config.debug
            @removeListener 'item-add', addItemListener
          return

      @framework.on 'after init', (context)=>
        deferred = Q.defer()
        # Give the other plugins some time to register asset files
        process.nextTick => 
          # and then setup the assets and manifest
          try
            @setupAssetsAndManifest()
          catch e
            env.logger.error "Error setting up assets in mobile-frontend: #{e.message}"
            env.logger.debug e.stack
          finally
            deferred.resolve()

        finished = deferred.promise.then( =>
          # If we are ind evelopment mode then
          if @config.mode is "development"
            # render the index page at each load.
            @app.get '/', (req,res) =>
              @renderIndex().then( (html) =>
                res.send html
              ).catch( (error) =>
                env.logger.error error.message
                env.logger.debug error.stack
                res.send error
              ).done()
            return Q()
          else 
            # In production mode render the index page on time and store it to a file
            return @renderIndex().then( (html) =>
              indexFile = __dirname + '/public/index.html'
              Q.nfcall(fs.writeFile, indexFile, html)
            )
          )
        context.waitForIt finished
        return

    renderIndex: () ->
      env.logger.info "rendering html"
      jade = require('jade')

      renderOptions = 
        pretty: @config.mode is "development"
        compileDebug: @config.mode is "development"
        globals: ["__", "nap", "i18n"]
        mode: @config.mode

      awaitingRenders = 
        for page in @additionalAssetFiles['html']
          page = path.resolve __dirname, '..', page
          switch path.extname(page)
            when '.jade'
              env.logger.debug("rendering: #{page}") if @config.debug
              Q.ninvoke jade, 'renderFile', page, renderOptions
            when '.html'
              Q.nfcall fs.readFile, page
            else
              env.logger.error "Could not add page: #{page} unknown extension."
              Q ""

      Q.all(awaitingRenders).then( (htmlPages) =>
        renderOptions.additionalPages = _.reduce htmlPages, (html, page) => html + page
        layout = path.resolve __dirname, 'app/views/layout.jade' 
        env.logger.debug("rendering: #{layout}") if @config.debug
        Q.ninvoke(jade, 'renderFile', layout, renderOptions).then( (html) =>
          env.logger.info "rendering html finished"
          return html
        )
      )


    registerAssetFile: (type, file) ->
      assert type is 'css' or type is 'js' or type is 'html'
      assert not @assetsPacked, "Assets are already packed. Please call this function only from" +
        "the pimatic 'after init' event."
      @additionalAssetFiles[type].push file

    setupAssetsAndManifest: () ->

      parentDir = path.resolve __dirname, '..'

      # Returns p.min.file versions of p.file when it exist
      minPath = (p) => 
        # Check if a minimised version exists:
        if @config.mode is "production"
          minFile = p.replace(/\.[^\.]+$/, '.min$&')
          if fs.existsSync parentDir + "/" + minFile then return minFile
        # in other modes or when not exist return full file:
        return p

      # Configure static assets with nap
      nap(
        appDir: parentDir
        publicDir: "pimatic-mobile-frontend/public"
        mode: @config.mode
        minify: false # to slow...
        assets:
          js:
            jquery: [
              minPath "pimatic-mobile-frontend/app/js/jquery-1.10.2.js"
              minPath "pimatic-mobile-frontend/app/js/jquery.mobile-1.3.2.js"
              minPath "pimatic-mobile-frontend/app/js/jquery.mobile.toast.js"
              minPath "pimatic-mobile-frontend/app/js/jquery-ui-1.10.3.custom.js"
              minPath "pimatic-mobile-frontend/app/js/jquery.ui.touch-punch.js"
              minPath "pimatic-mobile-frontend/app/js/jquery.mobile.simpledialog2.js"
            ]
            main: [
              "pimatic-mobile-frontend/app/scope.coffee"
              "pimatic-mobile-frontend/app/helper.coffee"
              "pimatic-mobile-frontend/app/connection.coffee"
              "pimatic-mobile-frontend/app/pages/*"
            ] .concat (minPath(f) for f in @additionalAssetFiles['js'])
            
          css:
            theme: [
              minPath "pimatic-mobile-frontend/app/css/theme/default/jquery.mobile-1.3.2.css"
              minPath "pimatic-mobile-frontend/app/css/themes/graphite/water/"+
                      "jquery.mobile-1.3.2.css"
              minPath "pimatic-mobile-frontend/app/css/jquery.mobile.toast.css"
              minPath "pimatic-mobile-frontend/app/css/jquery.mobile.simpledialog.css"
            ]
            style: [
              "pimatic-mobile-frontend/app/css/style.css"
            ] .concat (minPath(f) for f in @additionalAssetFiles['css'])
      )

      nap.preprocessors['.coffee'] = (contents, filename) ->
        try
          coffee.compile contents, bare: on
        catch err
          err.stack = "Nap error compiling #{filename}\n" + err.stack
          throw err


      # When the config mode 
      manifest = (switch @config.mode 
        # is production
        when "production"
          # then pack the static assets in "public/assets/"
          env.logger.info "packing static assets"
          nap.package()
          env.logger.info "packing static assets finished"
          renderManifest = require "render-appcache-manifest"
          # function to create the app manifest
          createAppManifest = =>
            # Collect all files in "public/assets"
            assets = ( "/assets/#{f}" for f in fs.readdirSync  __dirname + '/public/assets' )
            # Render the app manifest
            return renderManifest(
              cache: assets.concat [
                '/',
                '/socket.io/socket.io.js'
              ]
              network: ['*']
              fallback: []
              lastModified: new Date()
            )
          # Save the manifest. We don't need to generate it each request, because
          # files shouldn't change in production mode
          manifest = createAppManifest()
        # if we are in development mode
        when "development"
          # then serve the files directly
          @app.use nap.middleware
          # and cache nothing
          manifest = """
            CACHE MANIFEST
            NETWORK:
            *
          """
        else 
          env.logger.error "Unknown mode: #{@config.mode}!"
          ""
      )

      # If the app manifest is requested
      @app.get "/application.manifest", (req, res) =>
        # then deliver it
        res.statusCode = 200
        res.setHeader "content-type", "text/cache-manifest"
        res.setHeader "content-length", Buffer.byteLength(manifest)
        res.end manifest

    addNewItem: (item) ->
      @config.items.push item
      @jsonConfig.items = @config.items
      @framework.saveConfig()

      p = switch item.type
        when 'device'
          @getDeviceWithData(item)
        when 'header'
          Q.fcall => item
      p.then( (item) =>
        @emit 'item-add', item 
      )

    addAttributeNotify: (socket, item) ->
      device = @framework.getDeviceById item.id
      unless device? 
        env.logger.debug "device #{item.id} not found."
        return
      for attr of device.attributes 
        do (attr) =>
          env.logger.debug("adding listener for #{attr} of #{device.id}") if @config.debug
          device.on attr, attrListener = (value) =>
            env.logger.debug("attr change for #{attr} of #{device.id}: #{value}") if @config.debug
            @emitAttributeValue socket, device, attr, value
          socket.on 'disconnect', => 
            env.logger.debug("removing listener for #{attr} of #{device.id}") if @config.debug
            device.removeListener attr, attrListener
      return

    getItemsWithData: () ->
      items = []
      for item in @config.items
        do(item) =>
          switch item.type
            when "device"
              items.push @getDeviceWithData item
            when "header"
              items.push Q.fcall => item
            else
              errorMsg = "Unknown item type \"#{item.type}\""
              env.logger.error errorMsg
      return Q.all items

    getDeviceWithData: (item) ->
      assert item.id?
      device = @framework.getDeviceById item.id
      if device?
        item =
          type: "device"
          id: device.id
          name: device.name
          template: device.getTemplateName()
          attributes: _.cloneDeep device.attributes

        typeToString = (type) => 
          if typeof type is "function" then type.name
          else if Array.isArray type then "String"
          else "Unknown"

        attrValues = []
        for attrName of device.attributes
          item.attributes[attrName].type = typeToString device.attributes[attrName].type
          do (attrName) =>
            attrValues.push device.getAttributeValue(attrName).then (value) =>
              return name: attrName, value: value
        return Q.all(attrValues).then( (attrValues) =>
          for attr in attrValues
            item.attributes[attr.name].value = attr.value
          return item
        ).catch( (error) =>
          env.logger.error error.message
          env.logger.debug error.stack
          return item
        ) 
      else
        errorMsg = "No device to display with id \"#{item.id}\" found"
        env.logger.error errorMsg
        return Q.fcall =>
          type: "device"
          id: item.id
          name: ""
          attributes: {}
          error: errorMsg

    emitRuleUpdate: (socket, trigger, rule) ->
      socket.emit "rule-#{trigger}",
        id: rule.id
        condition: rule.orgCondition
        action: rule.action
        active: rule.active
        valid: rule.valid

    emitAttributeValue: (socket, device, name, value) ->
      socket.emit "device-attribute",
        id: device.id
        name: name
        value: value

  plugin = new MobileFrontend
  return plugin