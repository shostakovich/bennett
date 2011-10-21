class Build < ActiveRecord::Base
  belongs_to :project
  has_many :results, :autosave => true, :dependent => :destroy

  scope :recent_first, order('created_at DESC')

  before_create :create_default_results

  def last
    recent_first.limit(1)
  end

  def results_in_status(status)
    results.select {|r| r.in_status? status}.count
  end

  def short_hash
    commit_hash.try :[], 0..9
  end

  def status
    [:busy, :failed, :pending, :skipped].each do |status|
      return status unless results_in_status(status).zero?
    end
    :passed
  end

  def start_time
    results.first.start_time
  end

  def end_time
    results.last.end_time
  end

  def create_default_results
    project.commands.each do |command|
      results.build(:command => command)
    end
  end

  def has_commit_info?
    commit_hash.present? && commit_message.present? && commit_author.present? && commit_date.present?
  end

  # WORK

  def skip!
    results.each do |result|
      result.update_attribute :status_id, Result::STATUS[:skipped]
    end
  end

  def update_commit!
    git = Git.open(project.folder_path)
    git.reset_hard
    git.checkout(project.branch)
    git.pull
    git.checkout(commit_hash)
  end

  def build!
    update_commit!
    results.each do |result|
      result.update_attribute :start_time, Time.now
      if status == :failed
        result.update_attribute :status_id, Result::STATUS[:skipped]
      else
        result.update_attribute :status_id, Result::STATUS[:busy]
        commands = [ 'unset RAILS_ENV RUBYOPT BUNDLE_GEMFILE BUNDLE_BIN_PATH',
                     '([[ -s "$HOME/.rvm/scripts/rvm" ]] && source "$HOME/.rvm/scripts/rvm")',
                     "cd #{project.folder_path}",
                     "#{result.command.command}" ]
        res = system "#{commands.join(';')} > #{result.log_path} 2>&1"
        if res
          result.update_attribute :status_id, Result::STATUS[:passed]
        else
          result.update_attribute :status_id, Result::STATUS[:failed]
        end
      end
      result.update_attribute :end_time, Time.now
    end
  end

  def fetch_commit!
    git = Git.open(project.folder_path)
    git.fetch
    branch = git.branches["remotes/origin/#{project.branch}"] # TODO: make this smarter
    commit = branch.gcommit.log(1).first
    self.commit_hash = commit.sha
    self.commit_message = commit.message
    self.commit_author = commit.author.name
    self.commit_date = commit.date
    save!
  end
end
