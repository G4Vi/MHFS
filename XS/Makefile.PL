use 5.020002;
use ExtUtils::MakeMaker;
use File::Basename;
use Cwd qw(abs_path);
use Alien::Base::Wrapper ();

my %stuff = Alien::Base::Wrapper->new('Alien::libFLAC')->mm_args2(
    NAME              => 'MHFS::XS',
    VERSION_FROM      => 'lib/MHFS/XS.pm', # finds $VERSION, requires EU::MM from perl >= 5.5
    PREREQ_PM         => {}, # e.g., Module::Name => 1.1
    ABSTRACT_FROM     => 'lib/MHFS/XS.pm', # retrieve abstract from module
    AUTHOR            => 'G4Vi',
    LICENSE           => 'gpl_2',
    CCFLAGS           => '-Wall -std=c11'
);
WriteMakefile(%stuff);