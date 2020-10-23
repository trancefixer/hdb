#! /usr/bin/ruby

# Homepage: http://www.subspacefield.org/security/hdb/

require 'find'
require 'socket' # For getting hostname
require 'pathname'
require 'fileutils'
# OpenSSL's SHA-512 is 50% of the speed of SHA1 but I don't want to
# hear any complaints about security, and I don't want to have to go
# through the pain of changing hashes for as long as possible. Also,
# although SHA-256 outperforms it on small data, for large data,
# SHA-512 can actually be faster.
require 'digest/sha2'
# This is for asking for passwords and not echoing them.
# TODO: Test for presence, use system.("stty -echo") if not here.
# See CryptedBackup.get_passphrase method later.
# TODO: consider using this hash method as a way to rename files,
# rather than transfer them.  This could make this system more
# efficient than rsync for really large collections, since you
# wouldn't re-transfer the files when they're renamed/moved.
# TODO: consider an rsync-like library in ruby
# http://teamco-anthill.blogspot.com/2009/03/rrsync-ruby-rsync.html
# https://rubyforge.org/projects/six-rsync/
# TODO: don't compute hashes for hardlinks of individual files
require 'rubygems'
require 'highline/import'

# TODO: consider rewriting find_metadata to return first match only
# since most time seems to be spent doing this (3 seconds / file).

module HDB

  # Make these module-specific variables.  This is a funny ruby trick.
  class << self
    attr_accessor :verbose
    attr_accessor :debug
  end

  # TODO: Trap sigusr1 like dd to report status

  # TODO: Consider XML format so we can store filenames with newlines in
  # them.

  # Do we want to preserve access times by resetting them after hashing
  # or copying?
  PRESERVE_ATIME = true

  # Do we want to preserve owners and groups?
  PRESERVE_IDS = true

  # This class represents metadata (name, checksum, etc.)
  # about a file (generally, in a FileList).
  class Metadata

    # These are necessary for unit tests to work, as are all the other
    # places where I use attr_*.
    attr_reader :archive_filename
    # TODO: Consider storing in binary form to save half space.
    attr_reader :sha512hash
    attr_reader :mtime # stored as a Time value, not string or int!

    BUFSIZE = 8092
    NAHASH = '*' * 128

    # TODO: consider using keyword parameters instead of explicit symbol.
    # Or, try Class method constructors.

    def initialize(method=nil, *args)
      case method
      when :file then create_from_file(*args)
      when :parts then create_from_parts(*args)
      when :string then create_from_string(*args) # unused
        # if no method, do no intialization
      end
    end

    def create_from_file(absolute_filename, archive_filename, fsg=nil)
      @archive_filename = archive_filename.dup
      # NOTE: Cannot do File.new(absolute_filename).lstat in case absolute_filename
      # is a dangling symlink.
      stat = File.lstat(absolute_filename)
      @mtime = stat.mtime
      # If there's a FileSetGroup to access, then try to look up matching metadata
      # based on archive_filename and mtime.
      if fsg != nil
        partial_matches = fsg.find_metadata(@archive_filename, @mtime)
        HDB.debug and puts "Found #{partial_matches.length} possible matches."
        hashes = partial_matches.collect { |m| m.sha512hash }
        hashes = hashes.uniq
        hashes.length > 1 and raise "Inconsistent metadata from FileSetGroup (multiple SHA-512 hashes)"
        if hashes.length == 1
          HDB.verbose and puts "...found one entry in FileSetGroup, reusing SHA-512 hash."
          @sha512hash = hashes[0].dup
          return self
        end
      end
      HDB.verbose and puts "...computing SHA-512 hash."
      @sha512hash = genhash(absolute_filename)
      return self
    end

    def create_from_parts(archive_filename, mtime, sha512hash)
      @archive_filename = archive_filename.dup
      @sha512hash = sha512hash.dup
      @mtime = mtime.dup
      # This is for convenience in unittest.rb
      return self
    end

    # This is for reading the metadata from a saved file.
    def create_from_string(str)
      @sha512hash, mtime, @archive_filename = str.split(" ", 3)
      @mtime = Time.at(mtime.to_i(16))
      # This is for convenience in unittest.rb
      return self
    end

    # Generate a hash from a file on the disk.
    def genhash(absolute_filename)
      HDB.debug and puts "Absolute filename #{absolute_filename}"
      if File.file?(absolute_filename)
        HDB.debug and puts "Digesting"
        hash = Digest::SHA512.new
        # Save atime
        PRESERVE_ATIME and atime = File.stat(absolute_filename).atime
        File.open(absolute_filename, 'r') do |fh|
          while buffer = fh.read(BUFSIZE)
            hash << buffer
          end
        end
        # Reset atime, preserve mtime
        PRESERVE_ATIME and File.utime(atime, File.stat(absolute_filename).mtime, absolute_filename)
        return hash.to_s
      else
        HDB.debug and puts "Not a file"
        return NAHASH
      end
    end

    def get_abs_filename(relative_to)
      return File.join(relative_to, @archive_filename)
    end

    # to_s seems to be more useful than to_str EXCEPT when concatenating
    # strings proper, in which case you need to_str
    def to_s
      return "%s %08x %s" % [@sha512hash, @mtime.to_i, @archive_filename]
    end

    alias to_str to_s

    # This is a loose test for "equality" (as opposed to == which tests for identity).
    def eql?(fe)
      @archive_filename.eql?(fe.archive_filename) and @sha512hash.eql?(fe.sha512hash) and @mtime.eql?(fe.mtime)
    end

    # This is a way to select matching Metadata entries - see FileList.find_metadata
    def match?(archive_filename=nil, mtime=nil, sha512hash=nil)
      ((archive_filename == nil or @archive_filename.eql?(archive_filename)) and (mtime == nil or @mtime.eql?(mtime)) and (sha512hash == nil or @sha512hash.eql?(sha512hash)))
    end

    # this is a hash for use in Hash containers
    def hash
      if @sha512hash != nil
        return @sha512hash.to_i(16)
      else
        super
      end
    end

    # For sorting, sort by filename, not hash.  This is only done within
    # FileLists, when sorting, so we don't care about absolute
    # filenames, etc.
    def <=>(fe)
      @archive_filename <=> fe.archive_filename or @sha512hash <=> fe.sha512hash or @mtime <=> fe.mtime
    end

  end

  # This class represents a list of files
  # Can be read from or written to a file or related objects
  # Implements several set operations
  # TODO: consider inheriting from Array
  class FileList

    attr_reader :files

    # Initialize the class, either with a set of files or the empty set
    def initialize(files=[])
      @files = files.dup
    end

    # This is for easily comparing a list of filenames
    def filenames
      @files.collect { |f| f.archive_filename }
    end

    # Subtract a set of files from this set
    def subtract!(files)
      for f1 in files do
          @files.delete_if { |f2| f2.eql?(f1) }
      end
    end

    # Add a single metadata object to this set
    def push(metadata)
      @files.push(metadata)
    end

    # Initialize this FileList from a filename
    def read_file!(filename)
      File.open(filename, "r") do |f|
        self.read!(f)
      end
      # This is for convenience.
      return self
    end

    # Initialize this FileList from an open file
    def read!(file)
      @files = []
      while line = file.gets
        @files.push(Metadata.new(:string, line.chomp()))
      end
      return self
    end

    # Write this FileList to a filename
    def write_file(filename)
      File.open(filename, "w") do |f|
        self.write(f)
      end
    end

    # Write this FileList to an open file
    # TODO: consider rewriting in terms of self.to_s
    def write(file)
      self.files.each { |l| file.puts l }
    end

    def to_s
      tmp = ""
      self.files.each { |l| tmp += l.to_s + "\n" }
      tmp
    end

    alias to_str to_s

    def sort!
      self.files.sort!
    end

    def eql?(ob)
      @files.eql?(ob.files)
    end

    # Find all the metadata entries that match this spec.
    # TODO: This is so super-slow that I should not even bother unless I get something faster.
    def find_metadata(*args)
      @files.select { |m| m.match?(*args) }
    end

  end

  # This represents a set of files from a given host and a given directory
  # Basically a FileList plus hostname and directory
  # Primarily used to serialize list to/from disk
  # TODO: put a date on which this backup was made, in machine-readable and human-readable form
  class FileSet < FileList
    attr_reader :label
    # This has to be an accessor for unit tests to work
    attr_accessor :host
    attr_reader :dir
    attr_reader :prune_leading_dir

    VERSION = "3.2"
    MAJOR_VERSION, MINOR_VERSION = VERSION.split('.')
    INCREMENT=5000

    # Initialize this FileSet from a file, or nil for empty
    # TODO: fix for prune_leading_dir=false (esp. when copying)
    def initialize(*args)
      super(*args)
      @label = ''
      @prune_leading_dir = true
    end

    def write_file(filename)
      File.open(filename, "w") do |f|
        write(f)
      end
    end

    # Write entire state out to a file object
    # TODO: consider writing in terms of self.to_s
    def write(f)
      f.puts "Version: " + VERSION
      f.puts "Label: #{@label}"
      f.puts "Host: #{@host}"
      f.puts "Dir: #{@dir}"
      f.puts "Prune: " + (@prune_leading_dir ? "true" : "false")
      f.puts
      super(f)
    end

    def to_s
      tmp = ""
      tmp += "Version: #{VERSION}\n"
      tmp += "Label: #{@label}\n"
      tmp += "Host: #{@host}\n"
      tmp += "Dir: #{@dir}\n"
      tmp += "Prune: " + (@prune_leading_dir ? "true" : "false") + "\n"
      tmp += "\n"
      tmp += super
    end

    alias to_str to_s

    # Read in the entire state from a filename
    def read!(file)
      File.open(file, "r") do |f|
        while (s = f.gets.chomp) != ''
          header, value = s.split(": ")
          case header
          when 'Version'
            major, minor = value.split('.')
            # NOTE: This is where I'd do conversions to the latest format, I think
            major != MAJOR_VERSION and
              raise "File #{file} uses a different format (#{value}) than this program (#{VERSION}).  Please upgrade your groupdir"
          when 'Label'
            @label = value
          when 'Host'
            @host = value
          when 'Dir'
            @dir = value
          when 'Prune'
            @prune_leading_dir = (value == 'true')
          end
        end
        super(f)
      end
      return self
    end

    # This gets the absolute filename, usually relative to the
    # source directory, though you could specify another directory
    # here (such as the mountpount of a previously-written medium).
    def get_abs_filename(metadata, dir=@dir)
      return metadata.get_abs_filename(dir)
    end

    def normalize_path(dir)
      pn = Pathname.new(dir)
      # Get the absolute pathname, without symlinks, useless dots, or
      # multiple slashes.  This also eliminates a trailing slash.
      @dir = pn.realpath.to_s
      HDB.debug and "Absolute path of archive: #{@dir}"
      return @dirs
    end

    # Make this object from a directory on this host
    # NOTE: Could theoretically call this with one file instead of a
    # directory, but it is not recommended.
    def make!(dirs, label='', fsg=nil)
      @label = label
      dirs = normalize_path(dirs)
      @host = Socket.gethostname

      # TODO: This is inefficient since we are often pruning leading
      # paths while Find.find returns a full pathname.  Is there some
      # more sane way to call Find.find so it does not return full
      # pathnames?  Concatenating is likely to be faster than slicing.

      filename_list = []
      filename_list_len = 0
      Find.find(@dir) do |f|
        if f != @dir
          filename_list.push(f)
          filename_list_len += 1
          # Print a friendly message every INCREMENT files to let them know it's working.
          # TODO: Show how long it took to find that many files.
          # TODO: Convert to showing progress every N seconds.
          HDB.verbose and ((filename_list_len % INCREMENT) == 0) and puts "...#{filename_list_len} files..."
        end
      end
      HDB.verbose and puts "Found #{filename_list_len} files total."
      
      # Sort the list of filenames, because I think find returns them in
      # a moderately undefined order, and it's nice to see the metadata
      # creation happen in lexical order.
      filename_list.sort!

      if @prune_leading_dir
        if @dir == "/"
          leading_dir = @dir
        else
          leading_dir = @dir + File::SEPARATOR
        end
        HDB.debug and puts "Leading dir of archive: #{leading_dir}"
        leading_dir_len = leading_dir.length()
        # This forms a lexical closure with leading_dir_len, I hope.
        get_archive_filename = proc { |f| f.slice(leading_dir_len, f.length()) }
      else
        # TODO: This is currently untested.
        get_archive_filename = proc { |f| f }
      end
 
      filename_list_len = filename_list.length # just to be paranoid
      filename_list.each_index do |i|
        f = filename_list[i]
        HDB.verbose and puts "Creating metadata (##{i+1}/#{filename_list_len}) #{f}"
        begin
          m = Metadata.new(:file, f, get_archive_filename.call(f), fsg)
        rescue Errno::ENOENT
          # the file isn't there any more
          puts "...gone already"
        else
          self.push(m)
        end
      end

      self.sort!
      return self
    end

    # Compare two FileSets for identical content
    # By analogy with String.eql?
    def eql?(fs)
      fs.host.eql?(@host) and fs.dir.eql?(@dir) and fs.files.eql?(self.files)
    end

    # Copy all of the files in file_list onto destdir
    def copy(destdir)
      # Make sure destination is a directory
      File.directory? destdir or raise ArgumentError, "#{destdir} is not a directory"
      # Go through files in sorted order
      num_files = self.files.length()
      # These are the files that didn't get copied to the destination dir
      uncopied = []
      self.files.each_index do |i|
        fe = self.files[i]
        # This is the destination filename
        dest = File.join(destdir, fe.archive_filename)
        # If @prune_leading_dir=true, then all files lack the leading
        # directories, so we need to prepend them.
        if @prune_leading_dir
          src = Pathname.new(@dir) + fe.archive_filename
        else
          src = fe.archive_filename
        end
        HDB.verbose and puts "Copying (##{i+1}/#{num_files}) #{src} to #{dest}"
        begin
          # Try and copy f to dest
          # NOTE: FileUtils.copy_entry does not work for us since it operates recursively
          # NOTE: FileUtils.copy only works on files
          self.copy_entry(src, dest)
        rescue Errno::ENOSPC
          HDB.verbose and puts "... out of space"
          # If the source was a file, we might have a partial copy.
          # If the source was not a file, copying it is likely atomic.
          if File.file?(dest)
            begin
              File.delete(dest)
            rescue Errno::ENOENT
              # None of the file was copied.
            end
          end
          uncopied.push(fe)
        # TODO: This may happen if destination dir doesn't exist
        rescue Errno::ENOENT
          # Src file no longer exists (was removed) - remove from
          # FileSet, as if out of space.
          HDB.verbose and puts "... deleted before I could copy it!"
          uncopied.push(fe)
        end
      end
      self.subtract!(uncopied)
    end

    def copy_entry(src, dst)
      # NOTE: It was too verbose to print every copy twice.
      HDB.debug and puts "Copying entry #{src} to #{dst}"
      ols = File.lstat(src)
      # TODO: Copy other kinds of files here
      # TODO: Preserve permissions, mind the umask.
      if ols.symlink?
        target = File.readlink(src)
        FileUtils.ln_s target, dst
        # Set owner, group on destination
        PRESERVE_IDS and File.lchown(ols.uid, ols.gid, dst)
      end
      if ols.directory? or ols.file?
        if ols.directory?
          begin
            FileUtils.mkdir_p dst
          rescue Errno::EEXIST => e
            # If the directory aready exists, ignore error
            raise e unless File.directory? dst
          end
        else # file
          # TODO: test that destination parent dir exists
          # if not, it's indistinguishable from src not existing
          # with current exception model (Errno::ENOENT)
          FileUtils.copy(src, dst)
        end
        # Get another stat aftr the copying, etc.
        nls = File.lstat(src)
        # Reset access time on _source_
        PRESERVE_ATIME and File.utime(ols.atime, nls.mtime, src)
        # Set modification time on destination
        File.utime(ols.atime, nls.mtime, dst)
        # Set owner, group on destination
        PRESERVE_IDS and File.chown(nls.uid, nls.gid, dst)
      end
    end

    # TODO: Test this.
    # This is actually hard for a couple of reasons:
    #   * We may not have actually copied some of the files, and yet we
    #     copied the parent directories, so we cannot remove the parent
    #     directories.
    #   * Some of the items may be directories, so we must use rmdir rather
    #     than unlink.
    #   * We must remove leaf directories before parent directories.
    #   * We must operate on absolute pathnames, not archive pathnames.
    def erase
      HDB.verbose and puts "Erasing successfully-copied files"
      unlinkable = @files.collect do |x|
        f = get_real_filename(x)
        File.directory?(f) or File.symlink?(f)
      end
      # TODO: unlink them now.
      # TODO: rmdir directories, starting with child nodes first
      raise "erase unimplemented"
    end

  end

  # This class represents a group of FileSets.
  # Typically used to represent the FileSets saved in the groupdir.
  class FileSetGroup
    attr_reader :groupdir
    # All FileSets for this groupdir, by default.
    # This is a hash indexed by volid.
    attr_reader :filesets

    # Initialize, creating groupdir if it doesn't exist.
    def initialize(groupdir)
      groupdir = Pathname.new(groupdir)
      if not groupdir.directory?
        groupdir.exist? and raise ArgumentError, "#{groupdir} non-existent"
        groupdir.mkdir
      end
      @groupdir = groupdir.to_s
      @filesets = {}

      # Scan the groupdir and load all the FileSet objects it finds in
      # there (will recurse into subdirs).
      Find.find(@groupdir) do |f|
        if File.file?(f)
          HDB.verbose and print "Loading FileSet #{f}... "
          STDOUT.flush # to print to screen while we read
          fs = FileSet.new().read!(f)
          HDB.verbose and puts "label=#{fs.label} #files=#{fs.files.length}"
          # TODO: Print the label of each fileset after we read it.
          f[@groupdir + File::SEPARATOR] = ''
          HDB.debug and puts "Normalized name as #{f}"
          @filesets[f] = fs
        end
      end
    end

    # Remove FileSets from memory that don't match dirs/host provided.
    def filter!(dirs=nil, host=Socket.gethostname)
      # Normalize the input directories
      dirs = Pathname(dirs).realpath.to_s
      # Now filter out any fileset which doesn't match what we're backing up
      @filesets.each do |k, v|
        if ((host != nil and not v.host.eql?(host)) or (dirs != nil and dirs.index(v.dir) == nil))
          @filesets.delete(k)
        end
      end
    end

    # Given some information, locate a Metadata object within all the FileSets in this FSG.
    # Used to look up its SHA-512 hash, in some cases.
    def find_metadata(*args)
      results = []
      @filesets.each do |volid, fileset|
        results += fileset.find_metadata(*args)
      end
      return results
    end

    # Given a FileSet object, filter out all the files and directories already backed up in the other
    # files in the groupdir.  This assumes you call scan first.
    # TODO: What do I do about directories that are common to two FileSets?
    # TODO: What do I do about files that are in two FileSets with different @dirs? (e.g. aliasing)
    def filter(fs)
      @filesets.each do |k, v|
        # puts "Filtering #{k} #{v}"
        fs.subtract!(v.files)
      end
    end

    def get_fs_fn(volid)
      return File.join(@groupdir, volid)
    end

    # NOTE: This should not be done when updating a medium.
    def remove_fileset(volid)
      fn = get_fs_fn(volid)
      if File.exists?(fn)
        HDB.verbose and puts "Removing fileset for volume ID #{volid}"
        FileUtils.rm(fn)
        @filesets.delete(volid)
      end
    end

    # Factory method.
    # Done this way (instead of simply FileSet.new.make!() so that
    # during FileSet creation, we can access the metadata from the
    # FileSetGroup.
    def create_fileset(paths, label='', prune=true, lookup=false)
      if HDB.verbose
        puts "Creating list of files (this can take a long time) in..."
        paths.each() { |p| puts p }
      end
      return fs = FileSet.new.make!(paths, label, (lookup ? self : nil))
    end

    # Write the fileset out to a volid in the groupdir and update
    # this FSG object with the results.
    def write_fileset(fs, volid)
      fn = get_fs_fn(volid)
      HDB.verbose and puts "Writing out copied data to #{fn}"
      fs.write_file(fn)
      @filesets[volid] = fs
    end

  end

  if __FILE__ == $0
    require 'optparse'

    # NOTE: It would be nice to simply set these options globally and be
    # able to reference them anywhere, but when we run unittest.rb this
    # is loaded as a module and hence, no command-line options are
    # available.  So we laboriously pass verbose and debug around.

    $o = o = {}

    # NOTE: we can't actually use rsync; it doesn't let us easily know
    # what files it could copy onto the medium, and it won't ever support
    # a heuristic packing onto the medium.

    opts = OptionParser.new do |opts|
      # Set a banner, displayed at the top of the help screen.
      opts.banner = 'Usage: hdb [-e] [-d] [-v] [-s] [-p] [-c cmd] [-l label] [-f fstype] [-g groupdir] [-m mpoint] /dev/sdX /path/to/backup'

      # Define the options, and what they do
      o[:crypt] = false
      opts.on('-e', '--encrypt', 'Encrypt the hard drive medium using LUKS cryptsetup') do
        o[:crypt] = true
      end

      # TODO: Figure out how to support not having this on.  Impacts unit tests extensively.
      o[:prune] = true
      #opts.on('-p', '--prune', 'Prune leading directories when storing on backup medium') do
      #  o[:prune] = true
      #end

      # TODO: This should not be slow, it should be default.
      o[:lookup] = false
      opts.on('-l', '--lookup', 'Look up metadata (is very slow)') do
        o[:lookup] = true
      end

      o[:debug] = false
      opts.on('-d', '--debug', 'Turn on debugging information') do
        o[:debug] = true
        HDB.debug = true
      end

      o[:verbose] = false
      opts.on('-v', '--verbose', 'Output more information') do
        o[:verbose] = true
        HDB.verbose = true
      end

      o[:eject] = true
      opts.on('-s', '--skipeject', 'Skip ejecting the medium on successful completion') do
        o[:eject] = false
      end

      o[:profile] = false
      opts.on('-p', '--profile', "Profile the code") do
        o[:profile] = true
      end

      o[:command] = 'create'
      opts.on('-c', '--command CMD', 'Command to perform (CMD=create, ...)') do |cmd|
        case cmd
        when 'create'
          o[:command] = cmd

          # TODO: consider options to "add to" rather than overwrite a
          # disk requires a new paradigm, rsync-like algorithm rather than
          # copy, and most importantly, it means we must skip luksFormat
          # and mkfs!

          # TODO: add a method to reconstruct metadata from a backup
          # medium; this would be used if you want to mount such a medium,
          # modify some files, and then need to reconstruct metadata file.
          # Again, also means we must skip luksFormat and mkfs.

        else
          raise "Invalid command #{cmd}"
        end
      end

      o[:label] = ''
      opts.on('-l', '--label LABEL', 'Label for human consumption') do |label|
        o[:label] = label
      end

      o[:fstype] = 'reiserfs'
      opts.on('-f', '--fstype TYPE', 'Type of file system') do |type|
        o[:fstype] = type
      end

      if ENV.has_key?('HDB_GROUPDIR')
        o[:groupdir] = ENV['HDB_GROUPDIR']
      else
        o[:groupdir] = ENV['HOME'] + '/.hdb'
      end
      opts.on('-g', '--groupdir DIR', 'Group metadata directory') do |dir|
        o[:groupdir] = dir
        # NOTE: Already done by underlying filelist.rb class:
        # File.directory? dir or FileUtils.mkdir_p dir
      end
      # TODO: This isn't very object-oriented, but at least it bombs out
      # quickly if you've set it wrong.  Think about how to re-work
      # FileSetGroup to check this earlier.
      File.directory?(o[:groupdir]) or raise "Groupdir #{o[:groupdir]} not a directory.  Make it if you need to."

      o[:mpoint] = "/mnt"
      opts.on('-m', '--mpoint DIR', 'Mount point for medium') do |dir|
        o[:mpoint] = dir
      end

      opts.on('-h', '--help', 'Display this screen') do
        puts opts
        exit
      end
    end
    opts.parse!

    # Test that two command-line args are present
    unless ARGV.length >= 2
      puts opts
      exit(1)
    end

    File.directory? o[:mpoint] or raise "Invalid mountpoint #{o[:mpoint]} (not a directory)"

    o[:device_file] = ARGV[0]

    File.blockdev? o[:device_file] or raise "Error: #{o[:device_file]} is not a device file"

    # Second and subsequent elements
    o[:path] = ARGV[1..-1]

    o[:path].each do |i|
      File.directory? i or raise "Error: (#{i}) is not a directory"
    end

    # TODO: consider if this should be a mandatory argument or an option.
    # cryptsetup will not work without a label for the volume.
    o[:label].empty? and raise "Error: no label specified"

    # TODO: consider making one big partition on the device

    class << self
      def vsystem(desc, args, exception=nil)
        HDB.verbose and puts desc
        HDB.verbose and puts "Running #{args}"
        if not system(args)
          exception != nil and raise exception
        end
      end
    end

    # determine filesystem-specific options to mkfs.fstype
    # TODO: use inheritance instead of branching
    class FileSystem

      def initialize(type)
        @valid_types = [ "ext2", "ext3", "ext4", "reiserfs" ]
        @valid_types.index(type) or raise ArgumentError, "unknown filesystem type"
        @type = type
      end

      def label_args(label)
        if [ "ext2", "ext3", "ext4" ].index(@type)
          return "-L #{label}"
        end
        if @type == "reiserfs"
          # NOTE: --label will not be passed through as mkfs.reiserfs option
          return "-l #{label}"
        end
        raise ArgumentError, "unknown filesystem type"
      end

      def quiet_args
        if [ "ext2", "ext3", "ext4", "reiserfs" ].index(@type)
          return "-q"
        end
        raise ArgumentError, "unknown filesystem type"
      end

      def mkfs(label, device)
        la = label_args(label)
        qa = quiet_args()
        # TODO: Figure out how to get mkfs.reiserfs to shut up on STDERR
        return "mkfs -t #{@type} #{la} #{qa} #{device}"
      end

    end

    # Handle trivia related to hard drive
    class BackupVolume

      attr_reader :volid

      def initialize(fs, eject, device_file, label, mpoint, groupdir, volid=nil)
        @fs = fs
        @eject = eject
        @device = device_file
        @label = label
        @mpoint = mpoint
        if (volid != nil)
          @volid = volid
        else
          @volid = self.get_volume(groupdir)
        end
      end

      # Prompt the user for a new volume
      # TODO: Double-check that the user has the right volume in the
      # drive; find out what you can from the drive and make sure the
      # user wants to overwrite it.
      def get_volume(groupdir)
        volid = ask("Insert the volume and enter its number or zero to use a new volume: ") { |x| x.echo = true }
        # If volid=0, figure out the next label based on ~/.hdb
        if volid == '0'
          # TODO: This should be fancier, perhaps by loading FSG first and doing a search in memory.
          HDB.verbose and puts "Searching #{groupdir} for next available volume id."
          i = 1
          while File.exist? File.join(groupdir, i.to_s)
            i += 1
          end
          volid = i.to_s
          HDB.verbose and puts "Found #{volid} free - please label this medium appropriately!"
        else
          if File.file? File.join(groupdir, volid)
            response = ask("Are you sure you have inserted volume #{volid} and want to overwrite it? ") { |x| x.echo = true }
            # NOTE: casecmp returns 0 if they are equal
            if "yes".casecmp(response) == 0 or "y".casecmp(response) == 0
              puts "WARNING: Overwriting existing volume"
            else
              raise "Aborted by user decision"
            end
          end
        end
        return volid
      end

      def mkfs
        # make a filesystem on it
        to_dev_null = (HDB.verbose ? " > /dev/null" : "")
        HDB.vsystem("Making filesystem on #{@device}",
                    @fs.mkfs(@label, @device) + to_dev_null,
                    "Error trying to make file system")
      end

      def mount
        # mount it
        HDB.vsystem("Mounting #{@device} on #{@mpoint}",
                    "mount #{@device} #{@mpoint}",
                    "Error trying to mount file system")
      end

      def umount
        # unmount it
        HDB.vsystem("Unmounting #{@mpoint}", "umount #{@mpoint}", nil)
      end

      def eject
        @eject and HDB.vsystem("Ejecting #{@device}", "eject #{@device}", nil)
      end
    end

    class CryptedBackupVolume < BackupVolume

      def initialize(underlying_device, fs, eject, device_file, label, mpoint, groupdir, volid=nil)
        @underlying_device = underlying_device
        super(fs, eject, device_file, label, mpoint, groupdir, volid)
      end

      # NOTE: This is the only BackupVolume routine that must operate on the underlying device, not
      # the special device-mapper one, and so we must overload it here.
      def eject
        @eject and HDB.vsystem("Ejecting #{@underlying_device}", "eject #{@underlying_device}", nil)
      end

      def get_passphrase
        last = nil
        new = ask("Enter the passphrase: ") { |x| x.echo = "*" }
        # This will loop until user enters the same thing twice.
        while (not last.eql?(new))
          last = new
          new = ask("Enter the passphrase again: ") { |x| x.echo = "*" }
        end
        last
      end

      # NOTE: call this before format and open
      def set_passphrase
        @pass = get_passphrase()
      end

      # TODO: Should we ditch the parameter here in favor of member var?
      def format(underlying_device)
        # NOTE: to run cryptsetup quietly (no prompt about overwriting disk), use -q
        # TODO: encapsulate these two lines into vpopen or something.
        HDB.verbose and puts "Running cryptsetup luksFormat #{underlying_device} -"
        # NOTE: If you use puts here, it will keep carriage return in cryptsetup password and you will need to type ^J when manually accessing it
        IO.popen("cryptsetup luksFormat #{underlying_device} -", "w") { |f| f.print @pass }
        $? != 0 and raise "Error trying to format disk: #{$?}; it is probably already/still a LUKS device (try luksClose), or if you got a read-only error it's not inserted"
      end

      # TODO: Should we ditch the parameter here in favor of member var?
      def open(underlying_device)
        HDB.verbose and puts "Running cryptsetup --key-file - luksOpen #{underlying_device} #{@label}"
        IO.popen("cryptsetup --key-file - luksOpen #{underlying_device} #{@label}", "w") { |f| f.print @pass }
        $? != 0 and raise "Error trying to open disk: #{$?}"
      end

      def close
        HDB.vsystem("Closing encrypted file system", "cryptsetup luksClose #{@label}", nil)
      end
    end

    class BackupRoutine

      def initialize(o)
        @o = o
      end

      def get_new_volume(fs, eject, device_file, label, mpoint, groupdir)
        # Create a new backup volume object
        return BackupVolume.new(fs, eject, device_file, label, mpoint, groupdir)
      end

      def backup(bv)
        o = @o # ugly hack since I don't want to rewrite everything below
        # get a list of all the files in this directory that have already been backed up
        HDB.verbose and puts "Searching groupdir #{o[:groupdir]} for FileSets..."
        fsg = FileSetGroup.new(o[:groupdir])
        fsg.filter!(o[:path])

        # We've already done a mkfs by this point so go ahead and remove old metadata entry.
        # NOTE: Don't do this when merely updating a medium.
        fsg.remove_fileset(bv.volid)

        # Get all files the user wants to back up, and create or look up metadata.
        fs = fsg.create_fileset(o[:path], o[:label], o[:prune], o[:lookup])

        if HDB.debug
          puts "Dumping FileSet object:"
          fs.write(STDOUT)
        end

        # TODO: Filter out any files already backed up - needs testing
        # verbose and puts "Filtering out files that have already been backed up"
        # fsg.filter(fs)

        # Copy data to mount point
        HDB.verbose and puts "Copying files to #{o[:mpoint]}"
        fs.copy(o[:mpoint])

        # Write out the FileSet file in FSG.
        fsg.write_fileset(fs, bv.volid)
      end

      def main(fs)
        # TODO: Ideally, I'd put some loop here that continues to prompt for (create) new backup volumes
        # until the backup is done, by checking some kind of exception thrown for out-of-space conditions.
        bv = get_new_volume(fs, @o[:eject], @o[:device_file], @o[:label], @o[:mpoint], @o[:groupdir])
        bv.mkfs()
        bv.mount()
        # everything in this block has cleanup for exceptions
        begin
          backup(bv)
        # NOTE: do not just trap RuntimeException here, since we want to catch SIGINT (^c)
        ensure
          bv.umount()
        end
      end
    end

    # TODO: add support for TrueCrypt
    # truecrypt [--text] --create=VOLUME_PATH --encryption=AES --hash=whirlpool --filesystem=ext2
    # truecrypt [--text] -k"" --protect-hidden=no /dev/whatever /media/truecrypt1
    # See also: https://help.ubuntu.com/community/TruecryptHiddenVolume
    class CryptedBackupRoutine < BackupRoutine

      def get_new_volume(fs, eject, device_file, label, mpoint, groupdir)
        # Create a new backup volume object with the destination device set properly, once we do crypto magic
        return CryptedBackupVolume.new(device_file, fs, eject, "/dev/mapper/#{@o[:label]}", label, mpoint, groupdir)
      end

      def main(fs)
        # TODO: Ideally, I'd put some loop here that continues to prompt for (create) new backup volumes
        # until the backup is done, by checking some kind of exception thrown for out-of-space conditions.
        ebv = get_new_volume(fs, @o[:eject], @o[:device_file], @o[:label], @o[:mpoint], @o[:groupdir])
        ebv.set_passphrase()
        # This begins a protected area where we must clean up on exception
        ebv.format(@o[:device_file])
        begin
          ebv.open(@o[:device_file])
          ebv.mkfs()
          ebv.mount()
          begin
            backup(ebv)
          ensure
            ebv.umount()
          end
        ensure
          ebv.close()
        end
      end

    end

    class << self
      def cleanup(profile, code)
        if profile
          result = RubyProf.stop
          # Print a flat profile to text
          printer = RubyProf::FlatPrinter.new(result)
          printer.print(STDOUT, 0)
        end
        exit(code)
      end
    end

    if o[:profile]
      # TODO: profile this; it gets really slow with 1E6 files in your FSG
      require 'ruby-prof'
      RubyProf.start
    end
    begin
      fs = FileSystem.new(o[:fstype])
      if o[:crypt]
        CryptedBackupRoutine.new(o).main(fs)
      else
        BackupRoutine.new(o).main(fs)
      end
      # TODO: Should I make this a typed exception so I only trap my
      # own exceptions?
    rescue Exception => e
      $stderr.puts e
      cleanup(o[:profile],1)
    end
    # Only eject if no errors (otherwise we exited above)
    if o[:eject]
      HDB.vsystem("Ejecting #{o[:device_file]}", "eject #{o[:device_file]}", nil)
    end
    cleanup(o[:profile],0)
  end

end
