use 5.020002;
use ExtUtils::MakeMaker;
# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.
WriteMakefile(
    NAME              => 'Mytest',
    VERSION_FROM      => 'lib/Mytest.pm', # finds $VERSION, requires EU::MM from perl >= 5.5
    PREREQ_PM         => {}, # e.g., Module::Name => 1.1
    ABSTRACT_FROM     => 'lib/Mytest.pm', # retrieve abstract from module
    AUTHOR            => 'Sample Text <sample@>',
    #LICENSE           => 'perl',
    #Value must be from legacy list of licenses here
    #http://search.cpan.org/perldoc?Module%3A%3ABuild%3A%3AAPI
    LIBS              => ['-lFLAC'],
    DEFINE            => '', 
    INC               => '-I.', 
    # Un-comment this if you add C files to link with later:
    # OBJECT            => '$(O_FILES)', # link all the C files too
    CCFLAGS        => '-Wall -std=c11',
    OPTIMIZE       => '-O3',
);
