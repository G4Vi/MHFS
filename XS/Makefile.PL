use 5.020002;
use ExtUtils::MakeMaker;
use File::Basename;
use Cwd qw(abs_path);


use Config;
my $lddlflags = $Config{lddlflags};
my $include = '';
my $link_libFLAC = '-lFLAC';
my $myextlib = '';

# check for libflac inside of MHFS::XS otherwise attempt to use system libflac
my $selfLibFLACInclude = 'thirdparty/flac-1.3.3/include';
my $selfLibFLACStaticLib = 'thirdparty/flac-1.3.3/src/libFLAC/.libs/libFLAC-static.a';
my $usingSelfLibFLAC = 0; # change to 1 to force trying to use self libFLAC
if(! -d $selfLibFLACInclude) {
    die("Cannot find \$selfLibFLACInclude: $selfLibFLACInclude") if($usingSelfLibFLAC);
    print "Using system libFLAC\n";
}
else {
    die("Cannot find \$selfLibFLACStaticLib: $selfLibFLACStaticLib") if(! -f $selfLibFLACStaticLib);
    $usingSelfLibFLAC = 1;
    print "Using self libFLAC\n";
    $include   = "-I$selfLibFLACInclude $include";
    $link_libFLAC = '';
    $myextlib = $selfLibFLACStaticLib;
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
