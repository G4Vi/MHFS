use 5.020002;
use ExtUtils::MakeMaker;
use File::Basename;
use Cwd qw(abs_path);


use Config;
my $lddlflags = $Config{lddlflags};
my $include = '';
my $link_libFLAC = '-lFLAC';
my $myextlib = '';


my $useselflibflac = 1;
if($useselflibflac) {
    $include   = "-Ithirdparty/flac-1.3.3/include $include";
    
    #$link_libFLAC = '-Lthirdparty/flac-1.3.3/src/libFLAC/.libs -l:libFLAC-static.a'
    
    #$link_libFLAC = '-l:libFLAC-static.a';
    #$lddlflags = '-L'. abs_path(dirname($0)).'/thirdparty/flac-1.3.3/src/libFLAC/.libs ' . $lddlflags;

    $link_libFLAC = '';
    $myextlib = 'thirdparty/flac-1.3.3/src/libFLAC/.libs/libFLAC-static.a';

    #$lddlflags = '-Lthirdparty/flac-1.3.3/src/libFLAC/.libs -Wl,-Bstatic -lFLAC ' . $lddlflags;

    #$lddlflags = '-Wl,-rpath=' . abs_path(dirname($0)).'/thirdparty/flac-1.3.3/src/libFLAC/.libs '. $lddlflags;
}

WriteMakefile(
    NAME              => 'MHFS::XS',
    VERSION_FROM      => 'lib/MHFS/XS.pm', # finds $VERSION, requires EU::MM from perl >= 5.5
    PREREQ_PM         => {}, # e.g., Module::Name => 1.1
    ABSTRACT_FROM     => 'lib/MHFS/XS.pm', # retrieve abstract from module
    AUTHOR            => 'G4Vi',
    LICENSE           => 'gpl_2',
    LDDLFLAGS =>  $lddlflags,
    LIBS              => [$link_libFLAC],
    DEFINE            => '', 
    INC               =>  $include,
    MYEXTLIB =>        $myextlib,
    # OBJECT            => '$(O_FILES)', # link all the C files too
    CCFLAGS        => '-Wall -std=c11',
    
    OPTIMIZE       => '-O3',     
    #OPTIMIZE       => '-g',
);
