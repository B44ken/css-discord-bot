require 'discordrb'
require 'pry'
require 'json'
require 'fuzzystringmatch'
require_relative 'services/discord_message_sender'
require_relative 'services/building_service'
require_relative 'services/latex_service'

class Main
  SECRETS = JSON.parse(File.read('secrets.json'))
  IMAGE_DIRECTORY_URL = SECRETS["image_directory_url"]
  LATEX_DIRECTORY_RELATIVE_PATH = "latex"
  BOT_USER_ID = 468629052643868673

  bot = Discordrb::Commands::CommandBot.new(
    token: SECRETS["api_token"],
    client_id: SECRETS["api_client_id"],
    prefix: '~',
  )

  bot.ready() do |event|
    bot.game="~help"
  end

  bot.command(:help) do |event|
    fields = []
    fields << Discordrb::Webhooks::EmbedField.new(
      name: "General Commands",
      value:
        "**`~year <1-4, masters, alumni>`** - add your current academic status to your profile.\n"\
        "**`~purge <2-99>`** - remove the last `n` messages in channel (**admin only**)\n"\
        "**`~equation <latex command>`** - returns an image of a latex equation.\n"\
        "**`~help`** - return the help menu\n"\
        "\n\u200B"
    )

    fields << Discordrb::Webhooks::EmbedField.new(
      name: "Building Search Commands",
      value:
        "**`~whereis <buildingName || buildingCode>`** - return building details and location on map\n"\
        "**`~whereis list`** - return the list of all building codes and their associating names\n"
    )

    DiscordMessageSender.send_embedded(
      event.channel,
      title: "Help Menu",
      description: "Note: Arguments in <this format> do not require the '<', '>' characters\n\u200B",
      fields: fields,
    )
  end

  # run when command is ~latex
  bot.command(:equation) do |event|
    begin
      # Combine every word after 'latex' for multi word arguments (eg \frac{23 a}{32} )
      args = event.message.content.split(' ').drop(1).join(' ')

      # Clean for escaped latex characters
      clean_args = LatexService.sanitize(args)

      # if it renders properly then send the image
      # else return error
      if LatexService.render?(clean_args, LATEX_DIRECTORY_RELATIVE_PATH, 'formula')
        event.send_file(File.open(File.join(LATEX_DIRECTORY_RELATIVE_PATH, 'formula.png'), 'r'))
      else
        return_error(event.channel, 'Formula Didnt Compile')
      end

      # delete the files created
      LatexService.cleanup(LATEX_DIRECTORY_RELATIVE_PATH, 'formula')
    end
  end

  bot.command(:whereis) do |event|
    begin
      # Combine every word after 'whereis' for multi-word arguments (e.g. "Erie Hall")
      args = event.message.content.split(' ').drop(1).join(' ')
      if args == "list"
        building_list = BuildingService.gather_building_list
        DiscordMessageSender.send_embedded(
          event.channel,
          title: "Building List",
          fields: [
            Discordrb::Webhooks::EmbedField.new(name: "Codes", value: building_list[:codes], inline: true),
            Discordrb::Webhooks::EmbedField.new(name: "Full Names", value: building_list[:full_names], inline: true)
          ],
        )

      # If the argument matches a building
      elsif building_code = BuildingService.find_building(args)
        DiscordMessageSender.send_embedded(
          event.channel,
          title: "Building Search",
          image: Discordrb::Webhooks::EmbedImage.new(url: "#{IMAGE_DIRECTORY_URL}/#{building_code}.png"),
          description: BuildingService.get_building_name(building_code) + " (#{building_code})",
        )

      # Arguments did not match a command or building
      else
        return_error(event.channel, "Building or command could not be found."\
          "\n\nList of buildings can be found at **~whereis list**")
      end
    end
  end

  bot.command(:purge) do |event|
    return if command_sent_as_direct_message_to_bot? (event)

    # Number of messages is the command argument + 1 to delete command message itself
    num_messages = event.message.content.split(' ')[1].to_i + 1
    member = event.server.members.find { |member| member.id == event.user.id }

    if num_messages < 2 || num_messages > 100
      return_error(member.pm, "Invalid number of messages to be removed.\n\nCorrect usage: `~purge <2-99>`")
      return
    end

    unless member.permission?(:administrator)
      return_error(member.pm, "You do not have permission to use this command.")
      return
    end

    event.channel.prune(num_messages)
    return
  end

  bot.command(:year) do |event|
    return if command_sent_as_direct_message_to_bot? (event)

    event.message.delete

    year = event.message.content.split(' ').drop(1).join(' ').upcase
    server = event.server
    member = server.members.find { |member| member.id == event.user.id }

    year_roles = {
      "1" => server.roles.find { |role| role.name == "1st Year"},
      "2" => server.roles.find { |role| role.name == "2nd Year"},
      "3" => server.roles.find { |role| role.name == "3rd Year"},
      "4" => server.roles.find { |role| role.name == "4th Year"},
      "MASTERS" => server.roles.find { |role| role.name == "Masters"},
      "ALUMNI" => server.roles.find { |role| role.name == "Alumni"},
    }

    if !(year_roles.include? year)
      return_error(event.user.pm, "Invalid option. Please select from: `#{year_roles.keys.to_s}`")
      return
    end

    year_role = year_roles[year]

    if year_role
      begin
        member.add_role(year_role)
        previous_year_roles = member.roles.select { |role| (year_roles.values.include? role) && role != year_role }
        previous_year_roles.each { |role| member.remove_role(role) }
        DiscordMessageSender.send_embedded(
          member.pm,
          title: "Success",
          description: ":white_check_mark: Successfully added your year/status to your profile.",
        )
      rescue Discordrb::Errors::NoPermission
        return_error(member.pm, "Bot has insufficient permissions to modify your roles.")
      end
    else
      return_error(member.pm, "Bot was unable to find the associating role in the server. Please notify admin.")
    end
  end

  # event roles channel add role system
  # 
  # event messages will have a simple structure
  # first line is the role
  # then a buffer line
  # then a description of the event
  # example: 
  # @name
  # 
  # this event exists and some ohter stuff
  
  # this is the first function to add a reaction if the message fits that format
  bot.message(in: "#event-roles") do |event|
    # returns the role object
    role = event.message.role_mentions.first
    
    # matches against the regex of what roles are handles on the backend
    unless role.nil?
      event.message.react("✅")
    end
  end

  # function to add a role to someone who clicked it
  # makes sure its in the right channel with the right emote
  bot.reaction_add(in: "#event-roles", emoji: "✅") do |event|
    # returns a role object
    role = event.message.role_mentions.first

    # a weird way to get the member, which is an user that belongs to a server
    member = event.user.on(event.channel.server)

    # if the role isnt nil and it isnt a bot
    if !role.nil? && !event.user.bot_account?
      # if the user doesnt have the role
      # then add the role
      unless member.role?(role)
        member.add_role(role)
      end
    end
  end

  # function to remove a role from someone who unreacted
  # makes sure its in the right channel with the right emote
  bot.reaction_remove(in: "#event-roes", emoji: "✅") do |event|
    role = event.message.role_mentions.first

    member = event.user.on(event.channel.server)

    # if the role isnt nil and it isnt a bot
    if !role.nil? && !event.user.bot_account?
      # if the user has the role
      # then remove
      if member.role?(role)
        member.remove_role(role)
      end
    end
  end

  # end of functions relating to event-roles

  def self.command_sent_as_direct_message_to_bot?(event)
    if event.server.nil?
      return_error(event.user.pm, "This command can only be used in the Discord server. Try sending this command in the #bot-commands channel in the CSS server.")
      return true
    end
    return false
  end

  def self.return_error(channel, message)
    DiscordMessageSender.send_embedded(
      channel,
      title: "Error",
      description: ":bangbang: " + message,
    )
  end

  puts "This bot's invite URL is #{bot.invite_url}."
  puts 'Click on it to invite it to your server.'
  bot.run
end
