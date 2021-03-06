require "bundler"
require "testing_env"
require "core_formula_repository"
require "fileutils"

class IntegrationCommandTests < Homebrew::TestCase
  def cmd_output(*args)
    # 1.8-compatible way of writing def cmd_output(*args, **env)
    env = args.last.is_a?(Hash) ? args.pop : {}
    cmd_args = %W[
      -W0
      -I#{HOMEBREW_LIBRARY_PATH}/test/lib
      -rconfig
    ]
    cmd_args << "-rsimplecov" if ENV["HOMEBREW_TESTS_COVERAGE"]
    cmd_args << (HOMEBREW_LIBRARY_PATH/"../brew.rb").resolved_path.to_s
    cmd_args += args
    Bundler.with_original_env do
      ENV["HOMEBREW_BREW_FILE"] = HOMEBREW_PREFIX/"bin/brew"
      ENV["HOMEBREW_INTEGRATION_TEST"] = args.join " "
      ENV["HOMEBREW_TEST_TMPDIR"] = TEST_TMPDIR
      env.each_pair { |k,v| ENV[k] = v }

      read, write = IO.pipe
      begin
        pid = fork do
          read.close
          $stdout.reopen(write)
          $stderr.reopen(write)
          write.close
          exec RUBY_PATH, *cmd_args
        end
        write.close
        read.read.chomp
      ensure
        Process.wait(pid)
        read.close
      end
    end
  end

  def cmd(*args)
    output = cmd_output(*args)
    assert_equal 0, $?.exitstatus
    output
  end

  def cmd_fail(*args)
    output = cmd_output(*args)
    assert_equal 1, $?.exitstatus
    output
  end

  def testball
    "#{File.expand_path("..", __FILE__)}/testball.rb"
  end

  def test_prefix
    assert_equal HOMEBREW_PREFIX.to_s,
                 cmd("--prefix")
  end

  def test_version
    assert_match HOMEBREW_VERSION.to_s,
                 cmd("--version")
  end

  def test_cache
    assert_equal HOMEBREW_CACHE.to_s,
                 cmd("--cache")
  end

  def test_cache_formula
    assert_match %r{#{HOMEBREW_CACHE}/testball-},
                 cmd("--cache", testball)
  end

  def test_cellar
    assert_equal HOMEBREW_CELLAR.to_s,
                 cmd("--cellar")
  end

  def test_cellar_formula
    assert_match "#{HOMEBREW_CELLAR}/testball",
                 cmd("--cellar", testball)
  end

  def test_env
    assert_match %r{CMAKE_PREFIX_PATH="#{HOMEBREW_PREFIX}[:"]},
                 cmd("--env")
  end

  def test_prefix_formula
    assert_match "#{HOMEBREW_CELLAR}/testball",
                 cmd("--prefix", testball)
  end

  def test_repository
    assert_match HOMEBREW_REPOSITORY.to_s,
                 cmd("--repository")
  end

  def test_install
    assert_match "#{HOMEBREW_CELLAR}/testball/0.1", cmd("install", testball)
  ensure
    cmd("uninstall", "--force", testball)
    cmd("cleanup", "--force", "--prune=all")
  end

  def test_bottle
    cmd("install", "--build-bottle", testball)
    assert_match "Formula not from core or any taps",
                 cmd_fail("bottle", "--no-revision", testball)
    formula_file = CoreFormulaRepository.new.formula_dir/"testball.rb"
    formula_file.write <<-EOS.undent
      class Testball < Formula
        url "https://example.com/testball-0.1.tar.gz"
      end
    EOS
    HOMEBREW_CACHE.cd do
      assert_match(/testball-0\.1.*\.bottle\.tar\.gz/,
                   cmd_output("bottle", "--no-revision", "testball"))
    end
  ensure
    cmd("uninstall", "--force", "testball")
    cmd("cleanup", "--force", "--prune=all")
    formula_file.unlink unless formula_file.nil?
  end

  def test_uninstall
    cmd("install", testball)
    assert_match "Uninstalling testball", cmd("uninstall", "--force", testball)
  ensure
    cmd("cleanup", "--force", "--prune=all")
  end

  def test_cleanup
    (HOMEBREW_CACHE/"test").write "test"
    assert_match "#{HOMEBREW_CACHE}/test", cmd("cleanup", "--prune=all")
  end

  def test_readall
    repo = CoreFormulaRepository.new
    formula_file = repo.formula_dir/"foo.rb"
    formula_file.write <<-EOS.undent
      class Foo < Formula
        url "https://example.com/foo-1.0.tar.gz"
      end
    EOS
    alias_file = repo.alias_dir/"bar"
    alias_file.parent.mkpath
    FileUtils.ln_s formula_file, alias_file
    cmd("readall", "--aliases", "--syntax")
    cmd("readall", "Homebrew/homebrew")
  ensure
    formula_file.unlink unless formula_file.nil?
    repo.alias_dir.rmtree
  end

  def test_tap
    path = Tap::TAP_DIRECTORY/"homebrew/homebrew-foo"
    path.mkpath
    path.cd do
      shutup do
        system "git", "init"
        system "git", "remote", "add", "origin", "https://github.com/Homebrew/homebrew-foo"
        system "git", "add", "--all"
        system "git", "commit", "-m", "init"
      end
    end

    assert_match "homebrew/foo", cmd("tap")
    assert_match "homebrew/versions", cmd("tap", "--list-official")
    assert_match "1 tap", cmd("tap-info")
    assert_match "https://github.com/Homebrew/homebrew-foo", cmd("tap-info", "homebrew/foo")
    assert_match "https://github.com/Homebrew/homebrew-foo", cmd("tap-info", "--json=v1", "--installed")
    assert_match "Pinned homebrew/foo", cmd("tap-pin", "homebrew/foo")
    assert_match "homebrew/foo", cmd("tap", "--list-pinned")
    assert_match "Unpinned homebrew/foo", cmd("tap-unpin", "homebrew/foo")
    assert_match "Tapped", cmd("tap", "homebrew/bar", path/".git")
    assert_match "Untapped", cmd("untap", "homebrew/bar")
  ensure
    Tap::TAP_DIRECTORY.rmtree
  end

  def test_missing
    url = "file://#{File.expand_path("..", __FILE__)}/tarballs/testball-0.1.tbz"
    sha256 = "1dfb13ce0f6143fe675b525fc9e168adb2215c5d5965c9f57306bb993170914f"
    repo = CoreFormulaRepository.new
    foo_file = repo.formula_dir/"foo.rb"
    foo_file.write <<-EOS.undent
      class Foo < Formula
        url "#{url}"
        sha256 "#{sha256}"
      end
    EOS

    bar_file = repo.formula_dir/"bar.rb"
    bar_file.write <<-EOS.undent
      class Bar < Formula
        url "#{url}"
        sha256 "#{sha256}"
        depends_on "foo"
      end
    EOS

    cmd("install", "bar")
    cmd("uninstall", "foo")
    assert_match "foo", cmd("missing")
  ensure
    cmd("uninstall", "--force", "foo", "bar")
    cmd("cleanup", "--force", "--prune=all")
    foo_file.unlink unless foo_file.nil?
    bar_file.unlink unless bar_file.nil?
  end

  def test_doctor_check_path_for_trailing_slashes
    assert_match "Some directories in your path end in a slash",
      cmd_fail("doctor", "check_path_for_trailing_slashes",
               {"PATH" => ENV["PATH"] + File::PATH_SEPARATOR + "/foo/bar/"})
  end

  def test_doctor_check_for_anaconda
    mktmpdir do |path|
      anaconda = "#{path}/anaconda"
      python = "#{path}/python"
      FileUtils.touch anaconda
      File.open(python, "w") do |file|
        file.write("#! #{`which bash`}\necho -n '#{python}'\n")
      end
      FileUtils.chmod 0777, anaconda
      FileUtils.chmod 0777, python

      assert_match "Anaconda",
        cmd_fail("doctor", "check_for_anaconda",
                 {"PATH" => path + File::PATH_SEPARATOR + ENV["PATH"]})
    end
  end
end
