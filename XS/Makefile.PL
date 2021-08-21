use 5.020002;
use ExtUtils::MakeMaker;
use File::Basename;
use Cwd qw(abs_path);


use Config;
my $lddlflags = $Config{lddlflags};
my $include = '';

my $useselflibflac = 1;
if($useselflibflac) {
    $include   = "-Ithirdparty/flac-1.3.3/include $include";
    $lddlflags = '-Wl,-rpath=' . abs_path(dirname($0)).'/thirdparty/flac-1.3.3/src/libFLAC/.libs '. $lddlflags;
}

WriteMakefile(
    NAME              => 'MHFS::XS',
    VERSION_FROM      => 'lib/MHFS/XS.pm', # finds $VERSION, requires EU::MM from perl >= 5.5
    PREREQ_PM         => {}, # e.g., Module::Name => 1.1
    ABSTRACT_FROM     => 'lib/MHFS/XS.pm', # retrieve abstract from module
    AUTHOR            => 'G4Vi',
    #LICENSE           => 'perl',
    #Value must be from legacy list of licenses here
    #http://search.cpan.org/perldoc?Module%3A%3ABuild%3A%3AAPI
    LDDLFLAGS =>  $lddlflags,
    LIBS              => ['-lFLAC'],
    DEFINE            => '', 
    INC               =>  $include,
    # OBJECT            => '$(O_FILES)', # link all the C files too
    CCFLAGS        => '-Wall -std=c11',
    OPTIMIZE       => '-O3',
    #OPTIMIZE       => '-g',
);
