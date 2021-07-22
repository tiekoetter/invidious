class Invidious::Routes::V1Api < Invidious::Routes::BaseRoute
  # Fetches YouTube storyboards
  #
  # Which are sprites containing x * y preview
  # thumbnails for individual scenes in a video.
  # See https://support.jwplayer.com/articles/how-to-add-preview-thumbnails
  def storyboards(env)
    locale = LOCALES[env.get("preferences").as(Preferences).locale]?

    env.response.content_type = "application/json"

    id = env.params.url["id"]
    region = env.params.query["region"]?

    begin
      video = get_video(id, PG_DB, region: region)
    rescue ex : VideoRedirect
      env.response.headers["Location"] = env.request.resource.gsub(id, ex.video_id)
      return error_json(302, "Video is unavailable", {"videoId" => ex.video_id})
    rescue ex
      env.response.status_code = 500
      return
    end

    storyboards = video.storyboards
    width = env.params.query["width"]?
    height = env.params.query["height"]?

    if !width && !height
      response = JSON.build do |json|
        json.object do
          json.field "storyboards" do
            generate_storyboards(json, id, storyboards)
          end
        end
      end

      return response
    end

    env.response.content_type = "text/vtt"

    storyboard = storyboards.select { |storyboard| width == "#{storyboard[:width]}" || height == "#{storyboard[:height]}" }

    if storyboard.empty?
      env.response.status_code = 404
      return
    else
      storyboard = storyboard[0]
    end

    String.build do |str|
      str << <<-END_VTT
      WEBVTT
      END_VTT

      start_time = 0.milliseconds
      end_time = storyboard[:interval].milliseconds

      storyboard[:storyboard_count].times do |i|
        url = storyboard[:url]
        authority = /(i\d?).ytimg.com/.match(url).not_nil![1]?
        url = url.gsub("$M", i).gsub(%r(https://i\d?.ytimg.com/sb/), "")
        url = "#{HOST_URL}/sb/#{authority}/#{url}"

        storyboard[:storyboard_height].times do |j|
          storyboard[:storyboard_width].times do |k|
            str << <<-END_CUE
            #{start_time}.000 --> #{end_time}.000
            #{url}#xywh=#{storyboard[:width] * k},#{storyboard[:height] * j},#{storyboard[:width] - 2},#{storyboard[:height]}


            END_CUE

            start_time += storyboard[:interval].milliseconds
            end_time += storyboard[:interval].milliseconds
          end
        end
      end
    end
  end

  def captions(env)
    locale = LOCALES[env.get("preferences").as(Preferences).locale]?

    env.response.content_type = "application/json"

    id = env.params.url["id"]
    region = env.params.query["region"]?

    # See https://github.com/ytdl-org/youtube-dl/blob/6ab30ff50bf6bd0585927cb73c7421bef184f87a/youtube_dl/extractor/youtube.py#L1354
    # It is possible to use `/api/timedtext?type=list&v=#{id}` and
    # `/api/timedtext?type=track&v=#{id}&lang=#{lang_code}` directly,
    # but this does not provide links for auto-generated captions.
    #
    # In future this should be investigated as an alternative, since it does not require
    # getting video info.

    begin
      video = get_video(id, PG_DB, region: region)
    rescue ex : VideoRedirect
      env.response.headers["Location"] = env.request.resource.gsub(id, ex.video_id)
      return error_json(302, "Video is unavailable", {"videoId" => ex.video_id})
    rescue ex
      env.response.status_code = 500
      return
    end

    captions = video.captions

    label = env.params.query["label"]?
    lang = env.params.query["lang"]?
    tlang = env.params.query["tlang"]?

    if !label && !lang
      response = JSON.build do |json|
        json.object do
          json.field "captions" do
            json.array do
              captions.each do |caption|
                json.object do
                  json.field "label", caption.name
                  json.field "languageCode", caption.languageCode
                  json.field "url", "/api/v1/captions/#{id}?label=#{URI.encode_www_form(caption.name)}"
                end
              end
            end
          end
        end
      end

      return response
    end

    env.response.content_type = "text/vtt; charset=UTF-8"

    if lang
      caption = captions.select { |caption| caption.languageCode == lang }
    else
      caption = captions.select { |caption| caption.name == label }
    end

    if caption.empty?
      env.response.status_code = 404
      return
    else
      caption = caption[0]
    end

    url = URI.parse("#{caption.baseUrl}&tlang=#{tlang}").request_target

    # Auto-generated captions often have cues that aren't aligned properly with the video,
    # as well as some other markup that makes it cumbersome, so we try to fix that here
    if caption.name.includes? "auto-generated"
      caption_xml = YT_POOL.client &.get(url).body
      caption_xml = XML.parse(caption_xml)

      webvtt = String.build do |str|
        str << <<-END_VTT
        WEBVTT
        Kind: captions
        Language: #{tlang || caption.languageCode}


        END_VTT

        caption_nodes = caption_xml.xpath_nodes("//transcript/text")
        caption_nodes.each_with_index do |node, i|
          start_time = node["start"].to_f.seconds
          duration = node["dur"]?.try &.to_f.seconds
          duration ||= start_time

          if caption_nodes.size > i + 1
            end_time = caption_nodes[i + 1]["start"].to_f.seconds
          else
            end_time = start_time + duration
          end

          start_time = "#{start_time.hours.to_s.rjust(2, '0')}:#{start_time.minutes.to_s.rjust(2, '0')}:#{start_time.seconds.to_s.rjust(2, '0')}.#{start_time.milliseconds.to_s.rjust(3, '0')}"
          end_time = "#{end_time.hours.to_s.rjust(2, '0')}:#{end_time.minutes.to_s.rjust(2, '0')}:#{end_time.seconds.to_s.rjust(2, '0')}.#{end_time.milliseconds.to_s.rjust(3, '0')}"

          text = HTML.unescape(node.content)
          text = text.gsub(/<font color="#[a-fA-F0-9]{6}">/, "")
          text = text.gsub(/<\/font>/, "")
          if md = text.match(/(?<name>.*) : (?<text>.*)/)
            text = "<v #{md["name"]}>#{md["text"]}</v>"
          end

          str << <<-END_CUE
          #{start_time} --> #{end_time}
          #{text}


          END_CUE
        end
      end
    else
      webvtt = YT_POOL.client &.get("#{url}&format=vtt").body
    end

    if title = env.params.query["title"]?
      # https://blog.fastmail.com/2011/06/24/download-non-english-filenames/
      env.response.headers["Content-Disposition"] = "attachment; filename=\"#{URI.encode_www_form(title)}\"; filename*=UTF-8''#{URI.encode_www_form(title)}"
    end

    webvtt
  end

  def annotations(env)
    locale = LOCALES[env.get("preferences").as(Preferences).locale]?

    env.response.content_type = "text/xml"

    id = env.params.url["id"]
    source = env.params.query["source"]?
    source ||= "archive"

    if !id.match(/[a-zA-Z0-9_-]{11}/)
      env.response.status_code = 400
      return
    end

    annotations = ""

    case source
    when "archive"
      if CONFIG.cache_annotations && (cached_annotation = PG_DB.query_one?("SELECT * FROM annotations WHERE id = $1", id, as: Annotation))
        annotations = cached_annotation.annotations
      else
        index = CHARS_SAFE.index(id[0]).not_nil!.to_s.rjust(2, '0')

        # IA doesn't handle leading hyphens,
        # so we use https://archive.org/details/youtubeannotations_64
        if index == "62"
          index = "64"
          id = id.sub(/^-/, 'A')
        end

        file = URI.encode_www_form("#{id[0, 3]}/#{id}.xml")

        location = make_client(ARCHIVE_URL, &.get("/download/youtubeannotations_#{index}/#{id[0, 2]}.tar/#{file}"))

        if !location.headers["Location"]?
          env.response.status_code = location.status_code
        end

        response = make_client(URI.parse(location.headers["Location"]), &.get(location.headers["Location"]))

        if response.body.empty?
          env.response.status_code = 404
          return
        end

        if response.status_code != 200
          env.response.status_code = response.status_code
          return
        end

        annotations = response.body

        cache_annotation(PG_DB, id, annotations)
      end
    else # "youtube"
      response = YT_POOL.client &.get("/annotations_invideo?video_id=#{id}")

      if response.status_code != 200
        env.response.status_code = response.status_code
        return
      end

      annotations = response.body
    end

    etag = sha256(annotations)[0, 16]
    if env.request.headers["If-None-Match"]?.try &.== etag
      env.response.status_code = 304
    else
      env.response.headers["ETag"] = etag
      annotations
    end
  end

  def search_suggestions(env)
    locale = LOCALES[env.get("preferences").as(Preferences).locale]?
    region = env.params.query["region"]?

    env.response.content_type = "application/json"

    query = env.params.query["q"]?
    query ||= ""

    begin
      headers = HTTP::Headers{":authority" => "suggestqueries.google.com"}
      response = YT_POOL.client &.get("/complete/search?hl=en&gl=#{region}&client=youtube&ds=yt&q=#{URI.encode_www_form(query)}&callback=suggestCallback", headers).body

      body = response[35..-2]
      body = JSON.parse(body).as_a
      suggestions = body[1].as_a[0..-2]

      JSON.build do |json|
        json.object do
          json.field "query", body[0].as_s
          json.field "suggestions" do
            json.array do
              suggestions.each do |suggestion|
                json.string suggestion[0].as_s
              end
            end
          end
        end
      end
    rescue ex
      return error_json(500, ex)
    end
  end
end
