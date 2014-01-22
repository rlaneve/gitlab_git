# Gitlab::Git::Commit is a wrapper around native Grit::Repository object
# We dont want to use grit objects inside app/
# It helps us easily migrate to rugged in future
module Gitlab
  module Git
    class Repository
      include Gitlab::Git::Popen

      class NoRepository < StandardError; end

      # Default branch in the repository
      attr_accessor :root_ref

      # Full path to repo
      attr_reader :path

      # Directory name of repo
      attr_reader :name

      # Grit repo object
      attr_reader :grit

      # Alias to old method for compatibility
      alias_method :raw, :grit

      def initialize(path)
        @path = path
        @name = path.split("/").last
        @root_ref = discover_default_branch
      end

      def grit
        @grit ||= Grit::Repo.new(path)
      rescue Grit::NoSuchPathError
        raise NoRepository.new('no repository for such path')
      end

      # Returns an Array of branch names
      # sorted by name ASC
      def branch_names
        branches.map(&:name)
      end

      # Returns an Array of Branches
      def branches
        grit.branches.sort_by(&:name)
      end

      # Returns an Array of tag names
      def tag_names
        tags.map(&:name)
      end

      # Returns an Array of Tags
      def tags
        grit.tags.sort_by(&:name).reverse
      end

      # Returns an Array of branch and tag names
      def ref_names
        branch_names + tag_names
      end

      def heads
        @heads ||= grit.heads.sort_by(&:name)
      end

      def has_commits?
        !!Gitlab::Git::Commit.last(self)
      rescue Grit::NoSuchPathError
        false
      end

      def empty?
        !has_commits?
      end

      # Discovers the default branch based on the repository's available branches
      #
      # - If no branches are present, returns nil
      # - If one branch is present, returns its name
      # - If two or more branches are present, returns current HEAD or master or first branch
      def discover_default_branch
        if branch_names.length == 0
          nil
        elsif branch_names.length == 1
          branch_names.first
        elsif grit.head
          grit.head.name
        elsif branch_names.include?("master")
          "master"
        elsif
          branch_names.first
        end
      end

      # Archive Project to .tar.gz
      #
      # Already packed repo archives stored at
      # app_root/tmp/repositories/project_name/project_name-commit-id.tag.gz
      #
      def archive_repo(ref, storage_path, format = "tar.gz")
        ref = ref || self.root_ref
        commit = Gitlab::Git::Commit.find(self, ref)
        return nil unless commit

        extension = nil
        git_archive_format = nil
        pipe_cmd = nil

        case format
        when "tar.bz2", "tbz", "tbz2", "tb2", "bz2"
          extension = ".tar.bz2"
          pipe_cmd = "bzip"
        when "tar"
          extension = ".tar"
          pipe_cmd = "cat"
        when "zip"
          extension = ".zip"
          git_archive_format = "zip"
          pipe_cmd = "cat"
        else
          # everything else should fall back to tar.gz
          extension = ".tar.gz"
          git_archive_format = nil
          pipe_cmd = "gzip"
        end

        # Build file path
        file_name = self.name.gsub("\.git", "") + "-" + commit.id.to_s + extension
        file_path = File.join(storage_path, self.name, file_name)

        # Put files into a directory before archiving
        prefix = File.basename(self.name) + "/"

        # Create file if not exists
        unless File.exists?(file_path)
          FileUtils.mkdir_p File.dirname(file_path)
          file = self.grit.archive_to_file(ref, prefix, file_path, git_archive_format, pipe_cmd)
        end

        file_path
      end

      # Return repo size in megabytes
      def size
        size = popen('du -s', path).first.strip.to_i
        (size.to_f / 1024).round(2)
      end

      def search_files(query, ref = nil)
        if ref.nil? || ref == ""
          ref = root_ref
        end

        greps = grit.grep(query, 3, ref)

        greps.map do |grep|
          Gitlab::Git::BlobSnippet.new(ref, grep.content, grep.startline, grep.filename)
        end
      end

      # Delegate log to Grit method
      #
      # Usage.
      #   repo.log(
      #     ref: 'master',
      #     path: 'app/models',
      #     limit: 10,
      #     offset: 5,
      #   )
      #
      def log(options)
        default_options = {
          limit: 10,
          offset: 0,
          path: nil,
          ref: root_ref,
          follow: false
        }

        options = default_options.merge(options)

        grit.log(
          options[:ref] || root_ref,
          options[:path],
          max_count: options[:limit].to_i,
          skip: options[:offset].to_i,
          follow: options[:follow]
        )
      end

      # Delegate commits_between to Grit method
      #
      def commits_between(from, to)
        grit.commits_between(from, to)
      end

      def merge_base_commit(from, to)
        grit.git.native(:merge_base, {}, [to, from]).strip
      end

      def diff(from, to, *paths)
        grit.diff(from, to, *paths)
      end

      # Returns commits collection
      #
      # Ex.
      #   repo.find_commits(
      #     ref: 'master',
      #     max_count: 10,
      #     skip: 5,
      #     order: :date
      #   )
      #
      #   +options+ is a Hash of optional arguments to git
      #     :ref is the ref from which to begin (SHA1 or name)
      #     :contains is the commit contained by the refs from which to begin (SHA1 or name)
      #     :max_count is the maximum number of commits to fetch
      #     :skip is the number of commits to skip
      #     :order is the commits order and allowed value is :date(default) or :topo
      #
      def find_commits(options = {})
        actual_options = options.dup

        allowed_options = [:ref, :max_count, :skip, :contains, :order]

        actual_options.keep_if do |key, value|
          allowed_options.include?(key)
        end

        default_options = {pretty: 'raw', order: :date}

        actual_options = default_options.merge(actual_options)

        order = actual_options.delete(:order)

        case order
        when :date
          actual_options[:date_order] = true
        when :topo
          actual_options[:topo_order] = true
        end

        ref = actual_options.delete(:ref)

        containing_commit = actual_options.delete(:contains)

        args = []

        if ref
          args.push(ref)
        elsif containing_commit
          args.push(*branch_names_contains(containing_commit))
        else
          actual_options[:all] = true
        end

        output = grit.git.native(:rev_list, actual_options, *args)

        Grit::Commit.list_from_string(grit, output).map do |commit|
          Gitlab::Git::Commit.decorate(commit)
        end
      rescue Grit::GitRuby::Repository::NoSuchShaFound
        []
      end

      # Returns branch names collection that contains the special commit(SHA1 or name)
      #
      # Ex.
      #   repo.branch_names_contains('master')
      #
      def branch_names_contains(commit)
        output = grit.git.native(:branch, {contains: true}, commit)
        # The output is expected as follow
        #   fix-aaa
        #   fix-bbb
        # * master
        output.scan(/[^* \n]+/)
      end

      # Returns tag names collection that contains the special commit(SHA1 or name)
      #
      # Ex.
      #   repo.tag_names_contains('master')
      #
      def tag_names_contains(commit)
        output = grit.git.native(:tag, {contains: true}, commit)
        # The output is expected as follow
        # v1.4
        # v1.4.1
        # v1.4.2
        output.scan(/[^* \n]+/)
      end

      # Get refs hash which key is SHA1
      # and value is ref object(Grit::Head or Grit::Remote or Grit::Tag)
      def refs_hash
        # Initialize only when first call
        if @refs_hash.nil?
          @refs_hash = Hash.new { |h, k| h[k] = [] }

          grit.refs.each do |r|
            @refs_hash[r.commit.id] << r
          end
        end
        @refs_hash
      end
    end
  end
end
