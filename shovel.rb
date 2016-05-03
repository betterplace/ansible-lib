require 'rake'
require 'term/ansicolor'
require 'tins/xt'
require 'flowdock'
require 'yaml'
require 'shellwords'
require 'shovel/inventory_file'
require 'json'
require 'set'

class Shovel
  include Term::ANSIColor
  include Rake::DSL

  RELEASE_BRANCH = ENV['BRANCH'] || 'master'

  CACHE_FILE     = '.rake-cache'

  GITHUB_SHA_URL_FORMAT = 'https://github.com/betterplace/%s/commit/%s'
  GITHUB_TAG_URL_FORMAT = 'https://github.com/betterplace/%s/releases/tag/%s'

  module Utils
    def shortcut(filename)
      File.basename(filename).sub File.extname(filename), ''
    end
  end
  include Utils

  class GitTag < Struct.new(:time, :playbook, :inv, :user)
    include Term::ANSIColor
    extend Shovel::Utils

    REGEXP = /^provision_(\d{4}(?:_\d{2}){4})_(\S+)_(\S+)_(\S+)$/

    def self.parse(tag)
      if tag =~ REGEXP
        row = $~.captures
        row[0] = Time.new(*row[0].split(?_)).strftime '%FT%T'
        new(*row)
      end
    end

    def self.name(time, playbook, inventory, user)
      [
        'provision',
        time.strftime('%Y_%m_%d_%H_%M'),
        shortcut(playbook),
        shortcut(inventory),
        user
      ] * ?_
    end

    def to_s
      "#{yellow(time)} #{green("#{playbook}@#{inv}")} by #{red(user)}"
    end
  end

  def initialize(
    github_repo:,
    flowdock_api_token:,
    release_branch: RELEASE_BRANCH
  )
    github_repo =~ %r(\A[^/]+/[^/]+\z) or
      raise ArgumentError, 'github_repo must be of format foo/bar'
    @github_repo        = github_repo
    @flowdock_api_token = flowdock_api_token
    @release_branch     = release_branch
    @start_at           = Time.now
    @env_vars           = %i[ USER VERBOSE PREVIEW UNSAFE_ARGS PLAYBOOK INVENTORY ]
    @vars               = {}

    setup_all_tasks
    setup_exit_handler
  end

  attr_reader :release_branch

  private

  def setup_exit_handler
    at_exit  do
      unless File.exist?(CACHE_FILE) || @played_it
        vars = ENV.to_hash.subhash(*@env_vars).merge(@vars)
        File.secure_write(CACHE_FILE) { |f| Marshal.dump(vars, f) }
      end
    end
  end

  def env(name)
    if @env_vars.include?(name.to_sym)
      ENV[name.to_s]
    else
      fail red("attempt to access unsupported env var #{name} 😰")
    end
  end

  def pick_file(msg, var:, dir:, ext:)
    result =
      if value = env(var)
        value
      else
        begin
          path = complete prompt: bright_blue(msg) do |pattern|
            Dir[File.join(dir, "**/*#{ext}")].
              grep(/#{Regexp.quote(pattern)}/)
          end.to_s.strip
        end until File.exist?(path)
        path
      end.to_s
      result.empty? and fail red("missing #{var} env var 🙀")
      @vars[var] = result
      result
  end

  def pick(msg, choices)
    begin
      choice = complete prompt: bright_blue(msg) do |pattern|
        choices.grep(/#{Regexp.quote(pattern)}/)
      end.to_s.strip
    end until choices.member?(choice)
    choice
  end

  def ask?(re, prompt: nil)
    prompt and STDOUT.write prompt
    STDIN.gets.chomp =~ re
  end

  def red_box(*lines, shift: 4)
    size = lines.map(&:size).max
    shift = ' ' * shift
    [
      blink(red(shift + '┏' + "━" * size + '┓')),
      *lines.map { |l|
        shift + blink(red('┃')) + red(l.center(size)) + blink(red('┃'))
      },
      blink(red(shift + '┗' + "━" * size + '┛'))
    ] * ?\n
  end

  def smart_expand(file, dir, ext)
    result = if file.include? ?/
               File.expand_path(file)
             else
               File.join(dir, file)
             end
    File.extname(result).empty? and result << ext
    result
  end

  memoize_method def inventory
    i = pick_file('Inventory <TAB>? ', var: 'INVENTORY', dir: 'inventories', ext: '.ini')
    result = '-i '
    result << smart_expand(i, 'inventories', '.ini')
  end

  memoize_method def playbook
    p = pick_file('Playbook <TAB>? ', var: 'PLAYBOOK', dir: 'playbooks', ext: '.yml')
    result = smart_expand(p, 'playbooks', '.yml')
  end

  def production?
    inventory =~ /production\./
  end

  def staging?
    inventory =~ /staging\./
  end

  def development?
    inventory =~ /development\./
  end

  def playbook_config
    YAML.load_file playbook
  end

  def safe_mode_from_playbook
    not playbook_config.all? { |pb|
      pb.fetch('vars').fetch('safe_mode') == false
    }
  rescue KeyError
    nil
  end

  def safe_mode?
    case mode = safe_mode_from_playbook
    when nil
      production? || staging?
    else
      mode
    end
  end

  def preview?
    env(:PREVIEW).to_i == 1
  end

  def verbose?
    if env(:VERBOSE).to_i == 1
      '-vvvv'
    end
  end

  def branch_checked_out?
    `git rev-parse --abbrev-ref HEAD` =~ /^#@release_branch$/
  end

  def ensure_branch_is_synced
    if safe_mode?
      if branch_checked_out?
        puts green("branch #@release_branch is checked out, nice! 😸")
        if modified = modified_files?
          fail [
            red("found some modified files 😿"),
            "Commit these files first:",
            *modified.lines.map(&:chomp)
          ] * ?\n
        else
          puts green("no modified files, good job! 😸")
        end
        sh "git pull origin #@release_branch"
        sh "git push origin #@release_branch"
      else
        fail red("checkout of branch #@release_branch required for provisioning 😿")
      end
    end
  end

  def modified_files?
    `git ls-files -m`.full?
  end

  def unsafe_args
    if safe_mode?
      []
    elsif args = env(:UNSAFE_ARGS)
      args.split(/\s+/)
    end
  end

  memoize_method def selected_ansible_tags
    output = `ansible-playbook #{inventory} #{playbook} --list-tags`
    tags   = Set[]
    output.scan(/TAGS: \[([^\]]+)\]/) { tags.merge $1.split(/\s*,\s*/) }
    return [] if tags.empty?
    puts 'Enter tags separated by spaces (enter for none):',
      yellow(tags.sort.join(?\n))
    print "tags = "
    STDIN.gets.split(/\s+/)
  end

  def ansible_tags
    selected_tags = selected_ansible_tags
    unless selected_tags.empty?
      "--tags=#{selected_tags.join(?,)}"
    end
  end

  def do_play(dry: false)
    sh [
      'ansible-playbook',
      playbook,
      inventory,
      verbose?,
      *unsafe_args,
      *ansible_tags,
      *(%w[ --check --diff ] if dry)
    ].compact * ' '
    @played_it = !dry
  end

  memoize_method def current_sha
    `git rev-parse HEAD`.chomp
  end

  def github_sha_link
    "<a href=\"#{GITHUB_SHA_URL_FORMAT % [ @github_repo, current_sha ]}\">#{current_sha[0, 6]}</a>"
  end

  memoize_method def git_tag_name
    GitTag.name(@start_at, playbook, inventory, env(:USER))
  end

  def github_tag_link
    "<a href=\"#{GITHUB_TAG_URL_FORMAT % [ @github_repo, git_tag_name ]}\">#{git_tag_name}</a>"
  end

  def notify_flow
    duration = "%0.2f seconds" % (Time.now - @start_at)
    flow = Flowdock::Flow.new(
      api_token: @flowdock_api_token,
      source: "ansible",
      from: { name: "Provisionaire", address: "developers@betterplace.org" }
    )
    flow.push_to_team_inbox(
      subject: "Provisioned #@github_repo: #{shortcut(playbook)} / #{shortcut(inventory)}",
      content: "<p>Commit #{github_sha_link}, tag #{github_tag_link} was "\
               "provisioned via playbook <b>#{shortcut(playbook)}</b> for "\
               "inventory <b>#{shortcut(inventory)}</b> in #{duration}.</p>"\
               "<p>Tags were: #{selected_ansible_tags.empty? ? '<none>' : selected_ansible_tags * ?,}</p>",
      tags: [ "provision", env(:USER) ]
    )
    puts green("Notified the team in flowdock. 😽")
    puts "Total runtime was #{duration}."
  rescue => e
    fail red("Caught #{e.class}: #{e}")
  end

  def tags
    `git tag | grep ^provision`.lines.map { |tag|
      tag = Tag.parse(tag) or next
    }.compact
  end

  def nodesc(*)
  end

  def setup_task_load_argument_cache
    nodesc 'Load argument cache if existent'
    task :load_argument_cache do
      if File.exist?(CACHE_FILE)
        puts "Found cached variables:"
        vars = File.open(CACHE_FILE, 'rb') { |f| Marshal.load(f) }
        puts vars.sort_by(&:first).map { |pair|
          yellow("%#{vars.max_by { |name,| name.size }.first.size}s: %s" % pair)
        }
        if ask?(/\Ay\z/i, prompt:  'Use cached variables (y/n)? ')
          ENV.update vars
        end
        rm_f CACHE_FILE
      end
    end
  end

  def setup_task_sync_git
    nodesc 'Ensure the local release branch is synced'
    task :sync_git do
      ensure_branch_is_synced
    end
  end

  def setup_task_play
    nodesc 'Play the playbook, eventually with preview'
    task :play => :sync_git do
      if preview?
        do_play dry: true
        puts red_box(
          "Provisioning playbook #{shortcut(playbook).inspect} with "\
          "inventory #{shortcut(inventory).inspect} now?",
          "Type »YES« to proceed!"
        )
        if ask?(/\AYES\z/)
          do_play
        else
          puts "Have it your way, then. 😾"
        end
      else
        do_play
      end
    end
  end

  def setup_task_after_play
    nodesc 'Things to do after play'
    task :after_play do
      if @played_it && safe_mode?
        sh "git tag #{git_tag_name}"
        sh "git push origin -f #{git_tag_name}"
        notify_flow
      end
    end
  end

  def setup_task_provision
    nodesc "Provision current #@release_branch"
    task :provision => %i[ load_argument_cache play after_play ]
  end

  def setup_task_provision_list
    namespace :provision do
      desc "List previous provision runs"
      task :list do
        puts tags
      end
    end
  end

  memoize_method def inventory_file
    InventoryFile.read(inventory.sub('-i ', ''))
  end

  def fetch_host_set_name
    names = inventory_file.host_set_names
    pick('Hosts? ', names)
  end

  def setup_task_command
    namespace :provision do
      desc 'Execute command on a hosts set'
      task :command do
        host_set = fetch_host_set_name
        begin
          rc = 0
          loop do
            prompt  = black(rc == 0 ? on_green("#{rc}>") : on_red("#{rc}>")) << " "
            command = Readline.readline(prompt, true) or raise Interrupt
            command = Shellwords.escape(command)
            ansible = "ansible #{inventory} #{host_set} -f 1 -m shell -a #{command}"
            system ansible
            rc = $?.exitstatus
          end
        rescue Interrupt
        end
      end

      desc 'Fetch hostvars as JSON'
      task :hostvars do
        host_set = inventory_file[inventory_file.host_set_names.first]
        ansible = "ansible #{host_set.first.name} #{inventory} -f 1 -m debug -a 'var=hostvars'"
        result = IO.popen(ansible).read
        result.sub!(/^.*success >> /, '')
        jj JSON(result)
      end
    end
  end

  def setup_all_tasks
    private_methods.grep(/\Asetup_task_/).each { |setup| __send__(setup) }
  end
end
