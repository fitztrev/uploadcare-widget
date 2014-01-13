{
  namespace,
  jQuery: $,
  utils
} = uploadcare

namespace 'uploadcare.files', (ns) ->

  class ns.ObjectFile extends ns.BaseFile
    MP_MIN_SIZE: 25 * 1024 * 1024
    MP_PART_SIZE: 5 * 1024 * 1024
    MP_CONCURRENCY: 4

    constructor: (settings, @__file) ->
      super

      @fileSize = @__file.size
      @fileName = @__file.name or 'original'
      @fileType = @__file.type or 'application/octet-stream'
      @__notifyApi()

    __startUpload: ->
      if @fileSize < @MP_MIN_SIZE
        @directUpload()
      else
        @multipartUpload()

    __autoAbort: (xhr) ->
      @__uploadDf.always xhr.abort
      xhr

    directUpload: ->
      formData = new FormData()
      formData.append('UPLOADCARE_PUB_KEY', @settings.publicKey)
      if @settings.autostore
        formData.append('UPLOADCARE_STORE', '1')
      formData.append('file', @__file)

      @__autoAbort $.ajax
        xhr: =>
          # Naked XHR for progress tracking
          xhr = $.ajaxSettings.xhr()
          if xhr.upload
            xhr.upload.addEventListener 'progress', (e) =>
              @__uploadDf.notify(e.loaded / @fileSize)
          xhr
        crossDomain: true
        type: 'POST'
        url: "#{@settings.urlBase}/base/?jsonerrors=1"
        xhrFields: {withCredentials: true}
        headers: {'X-PINGOTHER': 'pingpong'}
        contentType: false # For correct boundary string
        processData: false
        data: formData
        dataType: 'json'
        error: @__uploadDf.reject
        success: (data) =>
          if data?.file
            @fileId = data.file
            @__uploadDf.resolve()
          else
            if @settings.autostore && /autostore/i.test(data.error.content)
              utils.commonWarning('autostore')
            @__uploadDf.reject()

    multipartUpload: ->
      if @settings.imagesOnly
        @__rejectApi 'image'
        return

      @multipartStart().done (data) =>
        @uploadParts(data.parts).done =>
          @multipartComplete(data.uuid).done (data) =>
            @fileId = data.uuid
            @__handleFileData(data)
            @__completeUpload()
          .fail @__uploadDf.reject
        .fail @__uploadDf.reject
      .fail @__uploadDf.reject

    multipartStart: ->
      data =
        UPLOADCARE_PUB_KEY: @settings.publicKey
        filename: @fileName
        size: @fileSize
        content_type: @fileType
      if @settings.autostore
        data.UPLOADCARE_STORE = '1'

      @__autoAbort utils.jsonp(
        "#{@settings.urlBase}/multipart/start/?jsonerrors=1", 'POST', data
      )

    uploadParts: (parts) ->
      progress = []
      updateProgress = (i, loaded) =>
        progress[i] = loaded
        total = 0
        for loaded in progress
          total += loaded
        @__uploadDf.notify(total / @fileSize)

      df = $.Deferred()

      inProgress = 0
      submittedParts = 0
      submittedBytes = 0
      submit = =>
        if submittedBytes >= @fileSize
          return

        if @__uploadDf.state() != 'pending'
          return

        progress.push(0)
        blob = @__file.slice(submittedBytes, submittedBytes + @MP_PART_SIZE)

        @__autoAbort $.ajax
          xhr: =>
            # Naked XHR for progress tracking
            xhr = $.ajaxSettings.xhr()
            if xhr.upload
              xhr.upload._part = submittedParts
              xhr.upload.addEventListener 'progress', (e) =>
                updateProgress(e.target._part, e.loaded)
            xhr
          url: parts[submittedParts]
          crossDomain: true
          type: 'PUT'
          processData: false
          contentType: @fileType
          data: blob
          error: df.reject
          complete: ->
            inProgress -= 1
            submit()
            if not inProgress
              df.resolve()

        submittedBytes += @MP_PART_SIZE
        inProgress += 1
        submittedParts += 1

      for i in [0...@MP_CONCURRENCY]
        submit()
      df

    multipartComplete: (uuid) ->
      data =
        UPLOADCARE_PUB_KEY: @settings.publicKey
        uuid: uuid

      @__autoAbort utils.jsonp(
        "#{@settings.urlBase}/multipart/complete/?jsonerrors=1", "POST", data
      )
