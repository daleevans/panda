use v6;
use Panda::Ecosystem;
use Panda::Fetcher;
use Panda::Builder;
use Panda::Tester;
use Panda::Installer;
use Panda::Mirrors;
use Panda::CPAN;
use Panda::Reporter;
use Shell::Command;
use JSON::Tiny;

sub tmpdir {
    state $i = 0;
    ".panda-work/{time}_{$i++}".IO.absolute
}

class Panda {
    has $.ecosystem;
    has $.mirrors;
    has $.cpan;
    has $.fetcher   = Panda::Fetcher.new;
    has $.builder   = Panda::Builder.new;
    has $.tester    = Panda::Tester.new;
    has $.installer = Panda::Installer.new;

    multi method announce(Str $what) {
        say "==> $what"
    }

    multi method announce('fetching', Panda::Project $p) {
        self.announce: "Fetching {$p.name}"
    }

    multi method announce('building', Panda::Project $p) {
        self.announce: "Building {$p.name}"
    }

    multi method announce('testing', Panda::Project $p) {
        self.announce: "Testing {$p.name}"
    }

    multi method announce('installing', Panda::Project $p) {
        self.announce: "Installing {$p.name}"
    }

    multi method announce('success', Panda::Project $p) {
        self.announce: "Successfully installed {$p.name}"
    }

    multi method announce('depends', Pair $p) {
        self.announce: "{$p.key.name} depends on {$p.value.join(", ")}"
    }

    method project-from-local($proj as Str) {
        if $proj.IO ~~ :d and "$proj/META.info".IO ~~ :f {
            my $mod = from-json slurp "$proj/META.info";
            $mod<source-url>  = $proj;
            return Panda::Project.new(
                name         => $mod<name>,
                version      => $mod<version>,
                dependencies => $mod<depends>,
                metainfo     => $mod,
            );
        }
        return False;
    }

    method project-from-git($proj as Str, $tmpdir) {
        if $proj ~~ m{^git\:\/\/} {
            mkpath $tmpdir;
            $.fetcher.fetch($proj, $tmpdir);
            my $mod = from-json slurp "$tmpdir/META.info";
            $mod<source-url>  = ~$tmpdir;
            return Panda::Project.new(
                name         => $mod<name>,
                version      => $mod<version>,
                dependencies => $mod<depends>,
                metainfo     => $mod,
            );
        }
        return False;
    }

    method look(Panda::Project $bone) {
        my $dir = tmpdir();

        self.announce('fetching', $bone);
        unless $bone.metainfo<source-url> {
            die X::Panda.new($bone.name, 'fetch', 'source-url meta info missing')
        }
        unless $_ = $.fetcher.fetch($bone.metainfo<source-url>, $dir) {
            die X::Panda.new($bone.name, 'fetch', $_)
        }

        my $shell = %*ENV<SHELL>;
        $shell ||= %*ENV<COMSPEC>
            if $*DISTRO.name eq 'mswin32';

        if $shell {

            my $*CWD = $dir;
            self.announce("Entering $dir with $shell\n");
            shell $shell or fail "Unable to invoke shell: $shell"
        } else {
            self.announce("You don't seem to have a SHELL");
        }
    }

    method install(Panda::Project $bone, $nodeps,
                   $notests, $isdep as Bool) {
        my $cwd = $*CWD;
        my $dir = tmpdir();
        self.announce('fetching', $bone);
        unless $bone.metainfo<source-url> {
            die X::Panda.new($bone.name, 'fetch', 'source-url meta info missing')
        }
        my @mirrors-list = $.mirrors.urls(self) if $bone.metainfo<source-url> ~~ /^ cpan '://' /;
        unless $_ = $.fetcher.fetch($bone.metainfo<source-url>, $dir, :@mirrors-list) {
            die X::Panda.new($bone.name, 'fetch', $_)
        }
        self.announce('building', $bone);
        unless $_ = $.builder.build($dir, :$bone) {
            die X::Panda.new($bone.name, 'build', $_)
        }
        unless $notests {
            self.announce('testing', $bone);
            unless $_ = $.tester.test($dir, :$bone) {
                die X::Panda.new($bone.name, 'test', $_, :$bone)
            }
        }
        self.announce('installing', $bone);
        $.installer.install($dir);
        my $s = $isdep ?? Panda::Project::State::installed-dep
                       !! Panda::Project::State::installed;
        $.ecosystem.project-set-state($bone, $s);
        self.announce('success', $bone);
        Panda::Reporter.new( :$bone ).submit;

        chdir $cwd;
        rm_rf $dir;

        CATCH {
            Panda::Reporter.new( :$bone ).submit;
            chdir $cwd;
            rm_rf $dir;
        }
    }

    method get-deps(Panda::Project $bone) {
        my @bonedeps = $bone.dependencies.grep(*.defined).map({
            $.ecosystem.get-project($_)
                or die X::Panda.new($bone.name, 'resolve',
                                    "Dependency $_ is not present in the module ecosystem")
        }).grep({
            $.ecosystem.project-get-state($_) == Panda::Project::State::absent
        });
        return () unless +@bonedeps;
        self.announce('depends', $bone => @bonedeps».name);
        my @deps;
        for @bonedeps -> $p {
            @deps.push: self.get-deps($p), $p;
        }
        return @deps;
    }

    method resolve($proj as Str is copy, Bool :$nodeps, Bool :$notests, :$action='install', Bool :$cpan, Bool :$github) {
        my $tmpdir = tmpdir();
        LEAVE { rm_rf $tmpdir if $tmpdir.IO.e }
        mkpath $tmpdir;
        my $p = self.project-from-local($proj);
        $p  ||= self.project-from-git($proj,  $tmpdir) if $github;
        if $p {
            if $.ecosystem.get-project($p.name) {
                self.announce: "Installing {$p.name} "
                               ~ "from a local directory '$proj'";
            }
            $.ecosystem.add-project($p);
            $proj = $p.name;
        }
        my $bone = $.ecosystem.get-project($proj) if $github;
        if $cpan {
            $.cpan.update(self);
            $bone ||= $.cpan.get-project($proj);
        }

        if not $bone {
            sub die($m) { X::Panda.new($proj, 'resolve', $m).throw }
            my $suggestion = $.ecosystem.suggest-project($proj);
            my $where = $cpan && $github
                      ?? 'in the ecosystem or on CPAN'
                      !! $github
                      ?? 'in the ecosystem'
                      !! 'on CPAN';
            die "Project $proj not found $where. Maybe you meant $suggestion?" if $suggestion;
            die "Project $proj not found $where";
        }
        unless $nodeps {
            my @deps = self.get-deps($bone).unique;
            @deps.=grep: {
                $.ecosystem.project-get-state($_)
                    == Panda::Project::absent
            };
            self.install($_, $nodeps, $notests, 1) for @deps;
        }

        given $action {
            when 'install' { self.install($bone, $nodeps, $notests, 0); }
            when 'look'    { self.look($bone) };
        }
    }
}

# vim: ft=perl6
