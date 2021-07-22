class Invidious::Routes::V1Api < Invidious::Routes::BaseRoute
  def home(env)
    locale = LOCALES[env.get("preferences").as(Preferences).locale]?

    env.response.content_type = "application/json"

    ucid = env.params.url["ucid"]
    sort_by = env.params.query["sort_by"]?.try &.downcase
    sort_by ||= "newest"

    begin
      channel = get_about_info(ucid, locale)
    rescue ex : ChannelRedirect
      env.response.headers["Location"] = env.request.resource.gsub(ucid, ex.channel_id)
      return error_json(302, "Channel is unavailable", {"authorId" => ex.channel_id})
    rescue ex
      return error_json(500, ex)
    end

    page = 1
    if channel.auto_generated
      videos = [] of SearchVideo
      count = 0
    else
      begin
        count, videos = get_60_videos(channel.ucid, channel.author, page, channel.auto_generated, sort_by)
      rescue ex
        return error_json(500, ex)
      end
    end

    JSON.build do |json|
      # TODO: Refactor into `to_json` for InvidiousChannel
      json.object do
        json.field "author", channel.author
        json.field "authorId", channel.ucid
        json.field "authorUrl", channel.author_url

        json.field "authorBanners" do
          json.array do
            if channel.banner
              qualities = {
                {width: 2560, height: 424},
                {width: 2120, height: 351},
                {width: 1060, height: 175},
              }
              qualities.each do |quality|
                json.object do
                  json.field "url", channel.banner.not_nil!.gsub("=w1060-", "=w#{quality[:width]}-")
                  json.field "width", quality[:width]
                  json.field "height", quality[:height]
                end
              end

              json.object do
                json.field "url", channel.banner.not_nil!.split("=w1060-")[0]
                json.field "width", 512
                json.field "height", 288
              end
            end
          end
        end

        json.field "authorThumbnails" do
          json.array do
            qualities = {32, 48, 76, 100, 176, 512}

            qualities.each do |quality|
              json.object do
                json.field "url", channel.author_thumbnail.gsub(/=s\d+/, "=s#{quality}")
                json.field "width", quality
                json.field "height", quality
              end
            end
          end
        end

        json.field "subCount", channel.sub_count
        json.field "totalViews", channel.total_views
        json.field "joined", channel.joined.to_unix
        json.field "paid", channel.paid

        json.field "autoGenerated", channel.auto_generated
        json.field "isFamilyFriendly", channel.is_family_friendly
        json.field "description", html_to_content(channel.description_html)
        json.field "descriptionHtml", channel.description_html

        json.field "allowedRegions", channel.allowed_regions

        json.field "latestVideos" do
          json.array do
            videos.each do |video|
              video.to_json(locale, json)
            end
          end
        end

        json.field "relatedChannels" do
          json.array do
            channel.related_channels.each do |related_channel|
              json.object do
                json.field "author", related_channel.author
                json.field "authorId", related_channel.ucid
                json.field "authorUrl", related_channel.author_url

                json.field "authorThumbnails" do
                  json.array do
                    qualities = {32, 48, 76, 100, 176, 512}

                    qualities.each do |quality|
                      json.object do
                        json.field "url", related_channel.author_thumbnail.gsub(/=\d+/, "=s#{quality}")
                        json.field "width", quality
                        json.field "height", quality
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
  end

  def latest(env)
    locale = LOCALES[env.get("preferences").as(Preferences).locale]?

    env.response.content_type = "application/json"

    ucid = env.params.url["ucid"]

    begin
      videos = get_latest_videos(ucid)
    rescue ex
      return error_json(500, ex)
    end

    JSON.build do |json|
      json.array do
        videos.each do |video|
          video.to_json(locale, json)
        end
      end
    end
  end

  def videos(env)
    locale = LOCALES[env.get("preferences").as(Preferences).locale]?

    env.response.content_type = "application/json"

    ucid = env.params.url["ucid"]
    page = env.params.query["page"]?.try &.to_i?
    page ||= 1
    sort_by = env.params.query["sort"]?.try &.downcase
    sort_by ||= env.params.query["sort_by"]?.try &.downcase
    sort_by ||= "newest"

    begin
      channel = get_about_info(ucid, locale)
    rescue ex : ChannelRedirect
      env.response.headers["Location"] = env.request.resource.gsub(ucid, ex.channel_id)
      return error_json(302, "Channel is unavailable", {"authorId" => ex.channel_id})
    rescue ex
      return error_json(500, ex)
    end

    begin
      count, videos = get_60_videos(channel.ucid, channel.author, page, channel.auto_generated, sort_by)
    rescue ex
      return error_json(500, ex)
    end

    JSON.build do |json|
      json.array do
        videos.each do |video|
          video.to_json(locale, json)
        end
      end
    end
  end

  def playlists(env)
    locale = LOCALES[env.get("preferences").as(Preferences).locale]?

    env.response.content_type = "application/json"

    ucid = env.params.url["ucid"]
    continuation = env.params.query["continuation"]?
    sort_by = env.params.query["sort"]?.try &.downcase ||
              env.params.query["sort_by"]?.try &.downcase ||
              "last"

    begin
      channel = get_about_info(ucid, locale)
    rescue ex : ChannelRedirect
      env.response.headers["Location"] = env.request.resource.gsub(ucid, ex.channel_id)
      return error_json(302, "Channel is unavailable", {"authorId" => ex.channel_id})
    rescue ex
      return error_json(500, ex)
    end

    items, continuation = fetch_channel_playlists(channel.ucid, channel.author, continuation, sort_by)

    JSON.build do |json|
      json.object do
        json.field "playlists" do
          json.array do
            items.each do |item|
              item.to_json(locale, json) if item.is_a?(SearchPlaylist)
            end
          end
        end

        json.field "continuation", continuation
      end
    end
  end

  def community(env)
    locale = LOCALES[env.get("preferences").as(Preferences).locale]?

    env.response.content_type = "application/json"

    ucid = env.params.url["ucid"]

    thin_mode = env.params.query["thin_mode"]?
    thin_mode = thin_mode == "true"

    format = env.params.query["format"]?
    format ||= "json"

    continuation = env.params.query["continuation"]?
    # sort_by = env.params.query["sort_by"]?.try &.downcase

    begin
      fetch_channel_community(ucid, continuation, locale, format, thin_mode)
    rescue ex
      return error_json(500, ex)
    end
  end

  def channel_search(env)
    locale = LOCALES[env.get("preferences").as(Preferences).locale]?

    env.response.content_type = "application/json"

    ucid = env.params.url["ucid"]

    query = env.params.query["q"]?
    query ||= ""

    page = env.params.query["page"]?.try &.to_i?
    page ||= 1

    count, search_results = channel_search(query, page, ucid)
    JSON.build do |json|
      json.array do
        search_results.each do |item|
          item.to_json(locale, json)
        end
      end
    end
  end
end
