use 5.020002;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME              => 'MHFS::XS',
    VERSION_FROM      => 'lib/MHFS/XS.pm', # finds $VERSION, requires EU::MM from perl >= 5.5
    PREREQ_PM         => {}, # e.g., Module::Name => 1.1
    ABSTRACT_FROM     => 'lib/MHFS/XS.pm', # retrieve abstract from module
    AUTHOR            => 'G4Vi',
    #LICENSE           => 'perl',
    #Value must be from legacy list of licenses here
    #http://search.cpan.org/perldoc?Module%3A%3ABuild%3A%3AAPI
    LIBS              => ['-lFLAC'],
    DEFINE            => '', 
    INC               => '-I.',
    # OBJECT            => '$(O_FILES)', # link all the C files too
    CCFLAGS        => '-Wall -std=c11',
    OPTIMIZE       => '-O3',
    #OPTIMIZE       => '-g',
);
