#! /usr/bin/ruby

require 'hdb'

require 'test/unit'

module HDB

  class MetadataTest < Test::Unit::TestCase

    FN = 'test_fl.in'

    def setup
      @pwd = Pathname.new('.').realpath.to_s
      @afn = File.join(@pwd, FN)
      @m = Metadata.new(:file, @afn, FN)
    end

    def test_constructor
      assert(@m.archive_filename == FN)
    end

    def test_hash
      sha512 = `sha512sum #{FN} | cut -f 1 -d" "`.chomp
      # puts "^" + sha512 + "$"
      # puts "^" + @fe.sha512hash + "$"
      assert(@m.sha512hash == sha512)
    end

    def test_match
      myattribs = [ @m.archive_filename, @m.mtime, @m.sha512hash ]
      # Iterate from 001 (=1) to 111 (=7) to get all permutations
      # where some attribute in the spec is not nil.
      for x in 1.."111".to_i(2)
        spec = [ nil, nil, nil ]
        for col in 0..(myattribs.length - 1)
          # If this digit of x is non-zero, set to non-nil
          x[col] != 0 and spec[col] = myattribs[col]
        end
        assert(@m.match?(*spec))
      end
    end

    def test_get_abs_filename
      assert(@m.get_abs_filename(@pwd) == @afn)
    end

  end

  # This only tests the set-theory operators, and so for convenience
  # operates on arrays of string rather than arrays of Metadata.
  class FileListSetTest < Test::Unit::TestCase

    def setup
      @fl = FileList.new(%w{ a b c })
    end

    def test_constructor
      assert(@fl.files == %w{ a b c })
    end

    def test_empty_constructor
      fl2 = FileList.new()
      assert(fl2.files == [])
    end

    def test_subtract!
      @fl.subtract!(["b"])
      assert(@fl.files == %w{ a c })
    end

    def test_push
      @fl.push("d")
      assert(@fl.files == %w{ a b c d })
    end

  end

  # These tests involve reading/writing FileLists and so need to operate
  # on arrays of Metadata.
  class FileListFileTest < Test::Unit::TestCase

    def setup
      # Quickly create a set of Metadata objects with bogus hashes.
      fns = %w{ a b c }
      mds = fns.collect { |fn| Metadata.new(:parts, fn, Time.at(0), "-") }
      @fl = FileList.new(mds)
    end

    def test_read_file!
      fl2 = FileList.new
      fl2.read_file!("test_fl.in")
      assert(fl2.filenames.eql?(%w{ a a/a b c }))
    end

    def test_write
      File.open("test_fl.out", "w") do |f|
        @fl.write(f)
      end
    end

    def test_write_file
      @fl.write_file("test_fl.out")
      fl2 = FileList.new
      # TODO: This doesn't create a/a in the archive for some reason.
      fl2.read_file!("test_fl.out")
      assert(@fl.eql?(fl2))
    end

    def test_find_metadata
      results = @fl.find_metadata('a', Time.at(0), '-')
      assert(results.length == 1)
    end
  end

  class FileSetTest < Test::Unit::TestCase

    def test_init_nil
      fs = FileSet.new()
      assert(fs.files == [])
    end

    def test_push
      fs = FileSet.new()
      fs.push('a')
      assert(fs.files == ['a'])
    end

    def test_subtract!
      fs1 = FileSet.new()
      %w{ a a/a b c }.each { |x| fs1.push(x) }
      fs1.subtract!(%w{ a })
      assert(fs1.files == %w{ a/a b c })
    end

  end

  class FileSetMakeTest < Test::Unit::TestCase

    def setup
      FileUtils.mkdir_p 'a/b'
      @fs = FileSet.new()
      # Create a metadata object for a/b
      @absfn = Pathname.new('a/b').realpath.to_s
      @m = Metadata.new(:file, @absfn, "b")
      @fs.make!('a')
      FileUtils.remove_dir('a')
    end

    def test_make_files
      assert(@fs.filenames.eql?(%w{ b }))
    end

    def test_make_dir_abs
      assert(@fs.dir[0,1] == '/')
    end

    def test_make_dir
      p = Pathname.new(@fs.dir)
      assert(p.basename.to_s == 'a')
    end

    def test_make_host
      assert(@fs.host == Socket.gethostname)
    end

    def test_write_file
      @fs.write_file('test_flc.out')
    end

    def test_find_metadata
      results = @fs.find_metadata(@m.archive_filename, @m.mtime, @m.sha512hash)
      assert(results.length == 1)
    end

    def test_get_abs_filename
      assert(@fs.get_abs_filename(@m) == @absfn)
    end

  end

  class FileSetReadTest < Test::Unit::TestCase

    def setup
      FileUtils.mkdir_p 'a/b'
      @fs = FileSet.new()
      @fs.make!('a')
      FileUtils.remove_dir('a')
      @fs.write_file('test_flc.out')
    end

    def test_init_file
      fs2 = FileSet.new.read!('test_flc.out')
      # puts fs2
      # puts fs2.filenames
      assert(fs2.filenames.eql?(%w{ b }))
    end

    def test_read
      fs = FileSet.new().read!("test_flc.out")
      assert(fs.filenames.eql?(%w{ b }))
    end

  end

  class FileSetCopyTest < Test::Unit::TestCase

    # Create a/b a/c a/e->d (dangling symlink) b/
    def setup
      FileUtils.mkdir_p 'a/b'
      FileUtils.touch 'a/c'
      FileUtils.ln_s 'd', 'a/e'
      FileUtils.mkdir_p 'b'
    end

    def exist?(f)
      # NOTE: Need this because File.exist? will fail on dangling symlink
      begin
        File.lstat f
        return true
      rescue Errno::ENOENT
        return false
      end
    end

    # test fs#copy_entry by copying these files into b subdir
    def test_copy_entry
      fs = FileSet.new()
      %w{ a a/b a/c a/e }.each do |f|
        dst = 'b/' + f
        fs.copy_entry(f, dst)
        assert(self.exist? dst)
      end
    end

    def test_copy
      fs1 = FileSet.new()
      fs1.make!('a')
      # puts `ls -laR a`
      fs1.copy('b')
      assert(File.directory? 'b')
      assert(File.directory? 'b/b')
      # puts `ls -laR b`
      assert(File.file? 'b/c')
      assert(File.symlink? 'a/e')
    end

    # recursively remove a and b subdirs after each test
    def teardown
      %w{ a b }.each { |f| FileUtils.remove_dir(f) }
    end

  end

  class FileSetGroupInitTest < Test::Unit::TestCase

    def test_make_groupdir
      # Remove the groupdir and do not throw an exception if that fails
      begin
        FileUtils.remove_dir('.hdb')
      rescue Errno::ENOENT
      end
      FileUtils.mkdir_p 'a'
      fg = FileSetGroup.new('.hdb')
      assert(FileTest.directory?('.hdb'))
      %w{ a .hdb }.each { |f| FileUtils.remove_dir(f) }
    end

  end

  class FileSetGroupCreateTest < Test::Unit::TestCase

    def test_create_fileset
      FileUtils.mkdir_p 'a/b'
      fg = FileSetGroup.new('.hdb')
      fs = fg.create_fileset('a')
      assert(fs.class == FileSet)
    end

    def teardown
      %w{ a .hdb }.each { |f| FileUtils.remove_dir(f) }
    end
  end

  class FileSetGroupTest < Test::Unit::TestCase

    def setup
      # Make a temporary groupdir to hold FileSets
      FileUtils.mkdir_p '.hdb'
      # Make a file set group for this directory.
      @fg = FileSetGroup.new('.hdb')
      # Make a directory a containing directory b
      FileUtils.mkdir_p 'a/b'
      # @fs1 is a fileset containing b
      @fs1 = FileSet.new().make!('a')
      # @fs2 is the same, only for an invalid hostname
      @fs2 = FileSet.new().make!('a')
      @fs2.host = "invalid"
      # Make a directory b containing a
      FileUtils.mkdir_p 'b/a'
      # @fs3 is a fileset containing a
      @fs3 = FileSet.new().make!('b')
      # Create a metadata object for a/b
      @m = Metadata.new(:file, Pathname.new('b/a').realpath.to_s, "a")
      # Store them as a, b, c respectively
      @fg.write_fileset(@fs1, 'a')
      @fg.write_fileset(@fs2, 'b')
      @fg.write_fileset(@fs3, 'c')
    end

    def test_groupdir
      assert(@fg.groupdir == '.hdb')
    end

    def test_scan
      # Check that three filesets were loaded during scan (a,b,c).
      assert(@fg.filesets.length == 3)
    end

    def test_filter!
      # Filter out all but the FileSet on a.
      @fg.filter!('a', nil)
      assert(@fs1.eql?(@fg.filesets['a']))
    end

    def TODO_test_filter
      # Make a/[bc] and create a fileset of it
      FileUtils.mkdir_p(['a/b', 'a/c'])
      fs = FileSet.new()
      fs.make!('a')
      # Find all matching FileSets (@fs1)
      @fg.filter('a')
      # Filter out what was in @fs1 (a/b)
      @fg.filter(fs)
      # puts fs.filenames
      assert(fs.filenames.eql?([ 'c' ]))
    end

    def test_write_fileset
      @fg.write_fileset(@fs1, 'a')
    end

    def test_find_metadata
      results = @fg.find_metadata(@m.archive_filename, @m.mtime, @m.sha512hash)
      assert(results.length == 1)
    end

    def teardown
      %w{ a b .hdb }.each { |f| FileUtils.remove_dir(f) }
    end

  end

end

