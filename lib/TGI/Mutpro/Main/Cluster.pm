package TGI::Mutpro::Main::Cluster;
#
#----------------------------------
# $Authors: Adam Scott & Sohini Sengupta
# $Date: 2014-01-14 14:34:50 -0500 (Tue Jan 14 14:34:50 CST 2014) $
# $Revision: 4 $
# $URL: $
# $Doc: $ determine mutation clusters from HotSpot3D inter, intra, and druggable data
# 
#----------------------------------
#
use strict;
use warnings;

use Carp;
use Cwd;
use Getopt::Long;

use List::MoreUtils qw( uniq );
use List::Util qw( min max );

use IO::File;
use FileHandle;
use File::Basename;

use Data::Dumper;

use TGI::Variant;
use TGI::ProteinVariant;
use TGI::Mutpro::Main::Density;

my $WEIGHT = "weight";
my $RECURRENCE = "recurrence";
my $UNIQUE = "unique";
my $PVALUEDEFAULT = 0.05;
my $DISTANCEDEFAULT = 10;
my $MAXDISTANCE = 10000;
my $AVERAGEDISTANCE = "average";
my $SHORTESTDISTANCE = "shortest";
my $NETWORK = "network";
my $DENSITY = "density";
my $INDEPENDENT = "independent";
my $DEPENDENT = "dependent";
my $ANY = "any";

sub new {
    my $class = shift;
    my $this = {};
    $this->{'pairwise_file'} = '3D_Proximity.pairwise';
    $this->{'maf_file'} = undef;
    $this->{'drug_clean_file'} = undef;
    $this->{'output_prefix'} = undef;
    $this->{'p_value_cutoff'} = undef;
    $this->{'3d_distance_cutoff'} = undef;
    $this->{'linear_cutoff'} = 0;
	$this->{'max_radius'} = 10;
	$this->{'vertex_type'} = $RECURRENCE;
	$this->{'distance_measure'} = $AVERAGEDISTANCE;
    $this->{'amino_acid_header'} = "amino_acid_change";
    $this->{'transcript_id_header'} = "transcript_name";
    $this->{'weight_header'} = $WEIGHT;
    $this->{'clustering'} = undef;
    $this->{'structure_dependence'} = undef;
	
	$this->{'processed'} = undef;
	$this->{'distance_matrix'} = undef;
	$this->{'mutations'} = undef;

    $this->{'Epsilon'} = undef;
    $this->{'MinPts'} = undef;
    $this->{'number_of_runs'} = undef;
    $this->{'probability_cut_off'} = undef;
    bless $this, $class;
    $this->process();
    return $this;
}

sub process {
    my $this = shift;
	$this->setOptions();
	my $clusterings = {};
	my $distance_matrix = {};
 	my $mutations = {};
	my $WEIGHT = "weight";
	$this->readMAF( $mutations );
#	foreach my $mk ( sort keys %{$mutations} ) {
#		foreach my $ra ( sort keys %{$mutations->{$mk}} ) {
#			foreach my $pk ( sort keys %{$mutations->{$mk}->{$ra}} ) {
#				print join( " -- " , ( $mk , $ra , $pk , $mutations->{$mk}->{$ra}->{$pk} ) )."\n";
#			}
#		}
#	}
	$this->getDrugMutationPairs( $distance_matrix );
	$this->getMutationMutationPairs( $distance_matrix );
	#$this->initializeSameSiteDistancesToZero( $distance_matrix );
	$this->link( $clusterings , $distance_matrix );
	$this->networkClustering( $clusterings , $mutations , $distance_matrix );
    return 1;
}
#####
#	sub functions
#####
sub setOptions {
	my $this = shift;
    my ( $help, $options );
    unless( @ARGV ) { die $this->help_text(); }
    $options = GetOptions (
        'output-prefix=s' => \$this->{'output_prefix'},
        'pairwise-file=s' => \$this->{'pairwise_file'},
        'drug-clean-file=s' => \$this->{'drug_clean_file'},
        'p-value-cutoff=f' => \$this->{'p_value_cutoff'},
        '3d-distance-cutoff=f' => \$this->{'3d_distance_cutoff'},
        'linear-cutoff=f' => \$this->{'linear_cutoff'},
        'max-radius=f' => \$this->{'max_radius'},
        'vertex-type=s' => \$this->{'vertex_type'},
        'number-of-runs=f' => \$this->{'number_of_runs'},
        'probability-cut-off=f' => \$this->{'probability_cut_off'},
        'distance-measure=s' => \$this->{'distance_measure'},
        'maf-file=s' => \$this->{'maf_file'},
        'amino-acid-header=s' => \$this->{'amino_acid_header'},
        'transcript-id-header=s' => \$this->{'transcript_id_header'},
        'weight-header=s' => \$this->{'weight_header'},
        'clustering=s' => \$this->{'clustering'},
        'structure-dependence=s' => \$this->{'structure_dependence'},
        'help' => \$help,
    );
    unless( $options ) { die $this->help_text(); }
	if ( not defined $this->{'clustering'} ) {
		$this->{'clustering'} = $NETWORK;
		warn "HotSpot3D::Cluster warning: no clustering option given, setting to default network\n";
	}
	if ( $this->{'clustering'} eq $DENSITY ) {
		if ( $help ) {
			die density_help_text();
		}
		else{
			TGI::Mutpro::Main::Density->new($this);
			exit;
		}
	}
	if ( $help ) { print STDERR help_text(); exit 0; }
	if ( not defined $this->{'structure_dependence'} ) {
		$this->{'structure_dependence'} = $INDEPENDENT;
		warn "HotSpot3D::Cluster warning: no structure-dependence option given, setting to default independent\n";
	}
	if ( not defined $this->{'subunit_dependence'} ) {
		$this->{'subunit_dependence'} = $INDEPENDENT;
		warn "HotSpot3D::Cluster warning: no subunit-dependence option given, setting to default independent\n";
	}
	if ( not defined $this->{'p_value_cutoff'} ) {
		if ( not defined $this->{'3d_distance_cutoff'} ) {
			warn "HotSpot3D::Cluster warning: no pair distance limit given, setting to default p-value cutoff = 0.05\n";
			$this->{'p_value_cutoff'} = $PVALUEDEFAULT;
			$this->{'3d_distance_cutoff'} = $MAXDISTANCE;
		} else {
			$this->{'p_value_cutoff'} = 1;
		}
	} else {
		if ( not defined $this->{'3d_distance_cutoff'} ) {
			$this->{'3d_distance_cutoff'} = $MAXDISTANCE;
		}
	}
	print STDOUT "p-value-cutoff = ".$this->{'p_value_cutoff'};
	print STDOUT " & 3d-distance-cutoff = ".$this->{'3d_distance_cutoff'}."\n";
	if ( defined $this->{'drug_clean_file'} ) {
		if ( not -e $this->{'drug_clean_file'} ) { 
			warn "The input drug pairs file (".$this->{'drug_clean_file'}.") does not exist! ", "\n";
			die $this->help_text();
		}
	} else {
		warn "HotSpot3D::Cluster::setOptions warning: no drug-clean-file included (cannot produce drug-mutation clusters)!\n";
	}
    if ( defined $this->{'pairwise_file'} ) {
		if ( not -e $this->{'pairwise_file'} ) { 
			warn "HotSpot3D::Cluster error: the input pairwise file (".$this->{'pairwise_file'}.") does not exist!\n";
			die $this->help_text();
		}
	} else {
		warn "HotSpot3D::Cluster error: must provide a pairwise-file!\n";
		die $this->help_text();
	}
	if ( $this->{'vertex_type'} ne $RECURRENCE
		 and $this->{'vertex_type'} ne $UNIQUE
		 and $this->{'vertex_type'} ne $WEIGHT ) {
		warn "vertex-type option not recognized as \'recurrence\', \'unique\', or \'weight\'\n";
		warn "Using default vertex-type = \'recurrence\'\n";
		$this->{'vertex_type'} = $RECURRENCE;
	}
	if ( $this->{'distance_measure'} ne $AVERAGEDISTANCE
		 and $this->{'distance_measure'} ne $SHORTESTDISTANCE ) {
		warn "distance-measure option not recognized as \'shortest\' or \'average\'\n";
		warn "Using default distance-measure = \'average\'\n";
		$this->{'distance_measure'} = $AVERAGEDISTANCE;
	}
	if ( $this->{'vertex_type'} ne $UNIQUE ) {
		unless( $this->{'maf_file'} ) {
			warn 'You must provide a .maf file if not using unique vertex type! ', "\n";
			die $this->help_text();
		}
		unless( -e $this->{'maf_file'} ) {
			warn "The input .maf file )".$this->{'maf_file'}.") does not exist! ", "\n";
			die $this->help_text();
		}
	}
	return;
}

sub getMutationMutationPairs {
	#$this->getMutationMutationPairs( $distance_matrix );
	my ( $this , $distance_matrix ) = @_;
	print STDOUT "HotSpot3D::Cluster getting pairwise data\n";
	$this->readPairwise( $distance_matrix );
	return;
}

sub readPairwise {
	#$this->readPairwise( $distance_matrix );
	my ( $this , $distance_matrix ) = @_;
	print STDOUT "\nReading in pairwise data ... \n";
	my $fh = new FileHandle;
	unless( $fh->open( $this->{'pairwise_file'} , "r" ) ) { die "Could not open pairwise file $! \n" };
	my $pdbCount;
	map {
		my ( $gene1 , $chromosome1 , $start1 , $stop1 , $aa_1 , $chain1 , $loc_1 , $domain1 , $cosmic1 , 
			 $gene2 , $chromosome2 , $start2 , $stop2 , $aa_2 , $chain2 , $loc_2 , $domain2 , $cosmic2 , 
			 $linearDistance , $infos ) = split /\t/ , $_;
		#print $_."\n";
		$chain1 =~ s/\[(\w)\]/$1/g;
		$chain2 =~ s/\[(\w)\]/$1/g;
		my $proteinMutation = TGI::ProteinVariant->new();
		my $mutation1 = TGI::Variant->new();
		$mutation1->gene( $gene1 );
		$mutation1->chromosome( $chromosome1 );
		$mutation1->start( $start1 );
		$mutation1->stop( $stop1 );
		$proteinMutation->aminoAcidChange( $aa_1 );
		$mutation1->addProteinVariant( $proteinMutation );

		my $mutation2 = TGI::Variant->new();
		$mutation2->gene( $gene2 );
		$mutation2->chromosome( $chromosome2 );
		$mutation2->start( $start2 );
		$mutation2->stop( $stop2 );
		$proteinMutation->aminoAcidChange( $aa_2 );
		$mutation2->addProteinVariant( $proteinMutation );
		$this->setDistance( $distance_matrix , $mutation1 , $mutation2 , 
							$chain1 , $chain2 , $infos , $pdbCount );
	} $fh->getlines;
	$fh->close();
	return;
}

sub readMAF{
	#$this->readMAF( $mutations );
	my ( $this , $mutations ) = @_;
	print STDOUT "HotSpot3D::Cluster::readMaf\n";
	my $fh = new FileHandle;
	die "Could not open .maf file\n" unless( $fh->open( $this->{'maf_file'} , "r" ) );
	my $headline = $fh->getline(); chomp( $headline );
	my $mafi = 0;
	my %mafcols = map{ ( $_ , $mafi++ ) } split( /\t/ , $headline );
	unless( defined( $mafcols{"Hugo_Symbol"} )
			and defined( $mafcols{"Chromosome"} )
			and defined( $mafcols{"Start_Position"} )
			and defined( $mafcols{"End_Position"} )
			and defined( $mafcols{"Reference_Allele"} )
			and defined( $mafcols{"Tumor_Seq_Allele2"} )
			and defined( $mafcols{"Tumor_Sample_Barcode"} )
			and defined( $mafcols{$this->{"transcript_id_header"}} )
			and defined( $mafcols{$this->{"amino_acid_header"}} ) ) {
		die "not a valid .maf file! Check transcript and amino acid change headers.\n";
	}
	my @mafcols = ( $mafcols{"Hugo_Symbol"},
					$mafcols{"Chromosome"},
					$mafcols{"Start_Position"},
					$mafcols{"End_Position"},
					$mafcols{"Variant_Classification"},
					$mafcols{"Reference_Allele"},
					$mafcols{"Tumor_Seq_Allele2"},
					$mafcols{"Tumor_Sample_Barcode"},
					$mafcols{$this->{"transcript_id_header"}},
					$mafcols{$this->{"amino_acid_header"}} );
	if ( $this->{'vertex_type'} eq $WEIGHT ) {
		unless( defined( $mafcols{$this->{"weight_header"}} ) ) {
			die "HotSpot3D::Cluster error: weight vertex-type chosen, but weight-header not recocgnized\n";
		};
		push @mafcols , $mafcols{$this->{"weight_header"}};
	}
	print STDOUT "\nReading in .maf ...\n";
	map {
		chomp;
		my @line = split /\t/;
		#print $_."\n";
		if ( $#line >= $mafcols[-1] && $#line >= $mafcols[-2] ) { #makes sure custom maf cols are in range
			my ( $gene , $chromosome , $start , $stop , $classification , $reference ,
				 $alternate , $barID , $transcript_name , $aachange );
			my $weight = 1;
			if ( $this->{'vertex_type'} eq $WEIGHT ) {
				( $gene , $chromosome , $start , $stop , $classification , $reference ,
				  $alternate , $barID , $transcript_name , $aachange , $weight
				) = @line[@mafcols];
			} else {
				( $gene , $chromosome , $start , $stop , $classification , $reference ,
				  $alternate , $barID , $transcript_name , $aachange 
				) = @line[@mafcols];
			}
			if ( $classification =~ /Missense/ 
				or $classification =~ /In_Frame/ ) {
				my $mutation = TGI::Variant->new();
				$mutation->gene( $gene );
				$mutation->chromosome( $chromosome );
				$mutation->start( $start );
				$mutation->stop( $stop );
				$mutation->reference( $reference );
				$mutation->alternate( $alternate );
				my $proteinMutation = TGI::ProteinVariant->new();
				$proteinMutation->transcript( $transcript_name );
				$proteinMutation->aminoAcidChange( $aachange );
				$mutation->addProteinVariant( $proteinMutation );
				$this->setMutation( $mutations , $mutation , $barID , $weight );
			} #if mutation is missense or in frame
		} #if columns in range
	} $fh->getlines; #map
	$fh->close();
	return;
}

sub setMutation {
	my ( $this , $mutations , $mutation , $barID , $weight ) = @_;
	my $mutationKey = $this->makeMutationKey( $mutation );
	my $refAlt = &combine( $mutation->reference() , $mutation->alternate() );
	my $proteinKey = $this->makeProteinKey( $mutation );
	#print "setMutation: ".$refAlt."\n";
	#print join( "\t" , ( $mutationKey , $proteinKey , $barID , $weight ) )." --- ";
	if ( exists $mutations->{$mutationKey}->{$refAlt}->{$proteinKey} ) {
		#print "existing\t";
		if ( $this->{'vertex_type'} ne $WEIGHT ) {
			$mutations->{$mutationKey}->{$refAlt}->{$proteinKey} += 1;
		} else {
			$mutations->{$mutationKey}->{$refAlt}->{$proteinKey} = $weight;
		}
	} else {
		#print "new\t";
		if ( $this->{'vertex_type'} eq $WEIGHT ) {
			$mutations->{$mutationKey}->{$refAlt}->{$proteinKey} = $weight;
		} else {
			$mutations->{$mutationKey}->{$refAlt}->{$proteinKey} += 1;
		}
	} #if mutation exists
	#my $w = $mutations->{$mutationKey}->{$refAlt}->{$proteinKey};
	#print $w."\t".$n."\n";
	return;
}

sub getMutationInfo {
	my ( $this , $mutations , $mutationKey ) = @_;
	my $weights = {};
	foreach my $refAlt ( sort keys %{$mutations->{$mutationKey}} ) {
		foreach my $proteinKey ( sort keys %{$mutations->{$mutationKey}->{$refAlt}} ) {
			my ( $transcript , $aaChange ) = @{$this->splitProteinKey( $proteinKey )};
			$aaChange =~ m/p\.(\D*)(\d+)(\D*)/;
			$weights->{$refAlt}->{$proteinKey} = $mutations->{$mutationKey}->{$refAlt}->{$proteinKey};
		}
	}
	return $weights;
}

sub networkClustering {
	#$this->finalize( $clusterings , $mutations , $distance_matrix );
	my ( $this , $clusterings , $mutations , $distance_matrix ) = @_;
	print STDOUT "HotSpot3D::Cluster::networkClustering\n";
	my $outFilename = $this->generateFilename();
	print STDOUT "Creating cluster output file: ".$outFilename."\n";
	my $fh = new FileHandle;
	die "Could not create clustering output file\n" unless( $fh->open( $outFilename , "w" ) );
	$fh->print( join( "\t" , ( 	"Cluster" , "Gene/Drug" , "Mutation/Gene" , 
								"Degree_Connectivity" , "Closeness_Centrality" , 
								"Geodesic_From_Centroid" , "Weight" , 
								"Chromosome" , "Start" , "Stop" , 
								"Reference" , "Alternate" ,
								"Transcript" , "Alternative_Transcripts"
							 )
					)."\n"
			  );
	print STDOUT "Clustering\n";
	foreach my $structure ( sort keys %{$distance_matrix} ) {
		foreach my $superClusterID ( sort keys %{$clusterings->{$structure}} ) {
			my $subClusterID = 0;
			$this->determineStructureClusters( $clusterings , $mutations , $distance_matrix , 
					$fh , $structure , $superClusterID , $subClusterID );
		}
	}
	$fh->close();
	return;
}

sub generateFilename {
	my $this = shift;
	my @outFilename;
	if ( $this->{'output_prefix'} ) {
		push @outFilename , $this->{'output_prefix'};
	} else {
		if ( $this->{'maf_file'} ) {
			my $maf = basename( $this->{'maf_file'} );
			push @outFilename , $maf;
		}
		if ( defined $this->{'drug_clean_file'} ) {
			my $clean = basename( $this->{'drug_clean_file'} );
			if ( $clean ne '' and scalar @outFilename > 1 ) {
				push @outFilename , $clean;
			} elsif ( $clean ne '' ) {
				push @outFilename , $clean;
			}
		}
		push @outFilename , "l".$this->{'linear_cutoff'};
		my $m = "a";
		if ( $this->{'distance_measure'} eq $SHORTESTDISTANCE ) { $m = "s"; }
		if ( $this->{'3d_distance_cutoff'} != $MAXDISTANCE ) {
            if ( $this->{'p_value_cutoff'} != 1 ) {
                push @outFilename , "p".$this->{'p_value_cutoff'};
                push @outFilename , $m."d".$this->{'3d_distance_cutoff'};
            } else {
                push @outFilename , $m."d".$this->{'3d_distance_cutoff'};
            }
        } else {
            if ( $this->{'p_value_cutoff'} != 1 ) {
                push @outFilename , "p".$this->{'p_value_cutoff'};
            }
        }
		push @outFilename , "r".$this->{'max_radius'};
	}
	push @outFilename , "clusters";
	return join( "." , @outFilename );
}

sub getDrugMutationPairs {
	#$this->getDrugMutationPairs( $distance_matrix );
	my ( $this , $distance_matrix ) = shift;
	print STDOUT "HotSpot3D::Cluster get drug mutation pairs\n";
	$this->readDrugClean( $distance_matrix );
	return;
}

sub readDrugClean {
	#$this->readDrugClean( $distance_matrix );
	my ( $this , $distance_matrix ) = shift;
	print STDOUT "HotSpot3D::Cluster read drug clean\n";
    if ( $this->{'drug_clean_file'} ) { #if drug pairs included
		my $fh = new FileHandle;
		unless( $fh->open( $this->{'drug_clean_file'} , "r" ) ) {
			die "Could not open drug pairs data file $! \n"
		};
		my $rxi = 0;
		my $headline = $fh->getline(); chomp( $headline );
		my %drugcols = map{ ( $_ , $rxi++ ) } split( /\t/ , $headline );
		my @required = ( "Drug" , "PDB_ID" , "Gene" , "Chromosome" , "Start" , 
						 "Stop" , "Amino_Acid_Change" , 
						 "Mutation_Location_In_PDB" ,
						 "3D_Distance_Information" );
		unless(	defined( $drugcols{"Drug"} )						#0
			and defined( $drugcols{"PDB_ID"} )						#2
			and defined( $drugcols{"Chain1"} )						#2
			and defined( $drugcols{"Gene"} )						#6
			and defined( $drugcols{"Chromosome"} )					#7
			and defined( $drugcols{"Start"} )						#8
			and defined( $drugcols{"Stop"} )						#9
			and defined( $drugcols{"Amino_Acid_Change"} )			#10
			and defined( $drugcols{"Chain2"} )						#2
			and defined( $drugcols{"Mutation_Location_In_PDB"} )	#12
			and defined( $drugcols{"3D_Distance_Information"} ) ) {	#17
			die "not a valid drug-clean file\n";
		}
		my @wantrxcols = (	$drugcols{"Drug"} ,
							$drugcols{"PDB_ID"} ,
							$drugcols{"Chain1"} ,
							$drugcols{"Gene"} ,
							$drugcols{"Chromosome"} ,
							$drugcols{"Start"} ,
							$drugcols{"Stop"} ,
							$drugcols{"Amino_Acid_Change"} ,
							$drugcols{"Chain2"} ,
							$drugcols{"Mutation_Location_In_PDB"} ,
							$drugcols{"3D_Distance_Information"} );
		my $pdbCount = {};
		map { 
				chomp;
				my @line = split /\t/; 
				map{ $_ =~ s/"//g } @line;
				my ( $drug, $pdb , $chain1 , $gene, 
					 $chromosome , $start , $stop , $aaChange , $chain2 , 
					 $loc, $infos ) = @line[@wantrxcols];
				#my ( $dist, $pdb2, $pval ) = split / /, $infos;
				$infos =~ s/"//g;
				my $structure = $this->structureDependent( $pdb , 
														   $chain1 , $chain2 );
				my $proteinMutation = TGI::ProteinVariant->new();
				my $mutation = TGI::Variant->new();
				$mutation->gene( $gene );
				$mutation->chromosome( $chromosome );
				$mutation->start( $start );
				$mutation->stop( $stop );
				$proteinMutation->aminoAcidChange( $aaChange );
				$mutation->addProteinVariant( $proteinMutation );
				my $soCalledMutation = TGI::Variant->new(); #for the purpose of making keys, will look like a mutation
				$soCalledMutation->gene( $gene );
				$soCalledMutation->chromosome( $drug );
				$soCalledMutation->start( $structure );
				$soCalledMutation->stop( $structure );
				$proteinMutation->aminoAcidChange( $aaChange );
				$soCalledMutation->addProteinVariant( $proteinMutation );
				$this->setDistance( $distance_matrix , $soCalledMutation , 
									$mutation , $chain1 , $chain2 , 
									$infos , $pdbCount );
		} $fh->getlines; 
		$fh->close();
	} #if drug pairs included
	return;
}

## NETWORK CLUSTERING - AGGLOMERATIVE HIERARCHICAL CLUSTERING
sub link {
	#$this->link( $clusterings , $distance_matrix );
	my ( $this, $clusterings , $distance_matrix ) = @_;
	print "linking: \n";
	foreach my $structure ( sort keys %{$distance_matrix} ) {
		print $structure."\n";
		foreach my $mutationKey1 ( sort keys %{$distance_matrix->{$structure}} ) {
			foreach my $mutationKey2 ( sort keys %{$distance_matrix->{$structure}->{$mutationKey1}} ) {
				my $distance = $distance_matrix->{$structure}->{$mutationKey1}->{$mutationKey2};
				#print join( "\t" , ( $pairKey , $mutationKey1 , $mutationKey2 , $distance , $pvalue ) )."\n";
				my @mutations = ( $mutationKey1 , $mutationKey2 );
				my ( $combine1 , $combine2 , $id ); 
				my @uniq;
				my @combine;
				foreach $id ( keys %{$clusterings->{$structure}} ) { #each cluster
					if ( exists $clusterings->{$structure}->{$id}->{$mutationKey1} ) {
						push @combine , $id;
					}
					if ( exists $clusterings->{$structure}->{$id}->{$mutationKey2} ) {
						push @combine , $id;
					}
				}
				&numSort( \@combine );
				if ( scalar @combine > 0 ) { #collapse clusters into one
					#if ( scalar @combine == 1 ) {
					#	print "\tadd to cluster\n";
					#} else {
					#	if ( $combine[0] != $combine[1] ) {
					#		print "\tcombine clusters\n";
					#	} else {
					#		print "\tsame cluster\n";
					#	}
					#}
					my $collapse_to = $combine[0]; #cluster type
					foreach my $otherClusters ( @combine ) {
						if ( $otherClusters != $collapse_to ) {
							foreach my $mutationKey ( keys %{$clusterings->{$structure}->{$otherClusters}} ) {
								$clusterings->{$structure}->{$collapse_to}->{$mutationKey} = 1;
								delete $clusterings->{$structure}->{$otherClusters}->{$mutationKey};
							}
							delete $clusterings->{$structure}->{$otherClusters};
						}
					}
					$clusterings->{$structure}->{$collapse_to}->{$mutationKey1} = 1;
					$clusterings->{$structure}->{$collapse_to}->{$mutationKey2} = 1;
				} else { #new cluster
					#print "\tnew cluster\n";
					my @ids = keys %{$clusterings->{$structure}};
					if ( scalar @ids > 0 ) {
						&numSort( \@ids );
						$id = $ids[-1] + 1;
					} else { $id = 0; }
					$clusterings->{$structure}->{$id}->{$mutationKey1} = 1;
					$clusterings->{$structure}->{$id}->{$mutationKey2} = 1;
				}
			} #foreach mutation2
		} #foreach mutation1
		my $nsuper = scalar keys %{$clusterings->{$structure}};
		print "there are ".$nsuper." superclusters in ".$structure."\n";
	} #foreach structure
    return;
}

sub initializeGeodesics {
	my ( $this , $clusterings , $superClusterID , $structure , $distance_matrix , $mutations ) = @_;
	print "initializeGeodesics: \n";
	my $geodesics = {};
	my $nInitialized = 0;
	my $nMutations = scalar keys %{$clusterings->{$structure}->{$superClusterID}};
	#print $nMutations." mutations to initialize geodesics\n";
	foreach my $mutationKey1 ( sort keys %{$clusterings->{$structure}->{$superClusterID}} ) { #initialize geodesics
		next if ( $this->hasBeenProcessed( $mutationKey1 ) );
		#print "need to process mutationKey1 = ".$mutationKey1.": \n";
		foreach my $mutationKey2 ( sort keys %{$clusterings->{$structure}->{$superClusterID}} ) {
			next if ( $this->hasBeenProcessed( $mutationKey2 ) );
			#next if ( exists $dist{$mutationKey1}{$mutationKey2} );
			#print "need to process mutationKey2 = ".$mutationKey2.": \n";
			my $distance = $this->getElementByKeys( $distance_matrix , 
									$structure , $mutationKey1 , 
									$mutationKey2 );
			$geodesics->{$structure}->{$mutationKey1}->{$mutationKey2} = $distance;
			$geodesics->{$structure}->{$mutationKey2}->{$mutationKey1} = $distance;
#			if ( $mutationKey1 =~ /4859191/ or $mutationKey2 =~ /4859191/ ) {
#				print "INITIALIZING FOR ".$mutationKey1." , ".$mutationKey2
			if ( $distance != $MAXDISTANCE ) { #NOTE if amino acids are neighboring, then a distance is given
				$nInitialized += 1;
				#print join( "\t" , ( "known" , $mutationKey1 , $mutationKey2 , $distance ) )."\n";
			} #if distance not known
			if ( $this->isSameProteinPosition( $mutations , $mutationKey1 , $mutationKey2 ) == 1 ) {
				print "same site: ".$mutationKey1."\t".$mutationKey2."\n";
				$geodesics->{$structure}->{$mutationKey1}->{$mutationKey2} = 0;
				$geodesics->{$structure}->{$mutationKey2}->{$mutationKey1} = 0;
				$nInitialized += 1;
			}
		} #foreach mutationKey2
	} #foreach mutationKey1
	print "nInitialized = ".$nInitialized."\n";
	return $geodesics;
}

sub isRadiusOkay {
	my ( $this , $geodesics , $structure , $mutationKey1 , $mutationKey2 ) = @_;
	print "isRadiusOkay of d(".$mutationKey1.",".$mutationKey2.") = ".$geodesics->{$structure}->{$mutationKey1}->{$mutationKey2}.": ";
	if ( $geodesics->{$structure}->{$mutationKey1}->{$mutationKey2} <= $this->{'max_radius'} ) {
		print "OKAY\n";
		return 1;
	}
	print "TOO LONG\n";
	return 0;
}

sub calculateClosenessCentrality {
	my ( $this , $mutations , $geodesics , $structure , $superClusterID , $subClusterID ) = @_;
	my $centrality = {};
	my $max=0;
	my $centroid = "NULL";
	my ( $mutationKey1 , $mutationKey2 , $weight );
	my $x = scalar keys %{$geodesics->{$structure}};
	print "calculateClosenessCentrality: ".$x." by ";
	foreach $mutationKey1 ( keys %{$geodesics->{$structure}} ) {
		my $y = scalar keys %{$geodesics->{$structure}->{$mutationKey1}};
		print $y."\n";
		#print "mutationKey1 = ".$mutationKey1."\t";
#TODO if alternative transcripts have different proref & proalt, then double counted
		foreach my $refAlt1 ( sort keys %{$mutations->{$mutationKey1}} ) {
			#print $refAlt1."\n";
			my $C = 0;
			my @proteinKeys1 = sort keys %{$mutations->{$mutationKey1}->{$refAlt1}};
			my $proteinKey1 = shift @proteinKeys1;
			#print $mutationKey1."|".$proteinKey1."\n";
			foreach $mutationKey2 ( keys %{$geodesics->{$structure}->{$mutationKey1}}) {
#TODO take only contributions within radius of centroid
				#next if ( not $this->isRadiusOkay( $geodesics , $structure , $mutationKey1 , $mutationKey2 ) );
				foreach my $refAlt2 ( sort keys %{$mutations->{$mutationKey2}} ) {
					#print $refAlt2."\n";
					my @proteinKeys2 = sort keys %{$mutations->{$mutationKey2}->{$refAlt2}};
					my $proteinKey2 = shift @proteinKeys2;
					#print "\t".$mutationKey2."|".$proteinKey2."\t";
					$weight = 1;
					if ( $this->{'vertex_type'} ne $UNIQUE ) {
						if ( exists $mutations->{$mutationKey2} ) {
							$weight = $mutations->{$mutationKey2}->{$refAlt2}->{$proteinKey2};
						}
					}
					#print join( "\t" , ( $weight , $geodesics->{$structure}->{$mutationKey1}->{$mutationKey2} ) )."\t";
					if ( $mutationKey1 ne $mutationKey2 ) {
						$C += $weight/( 2**$geodesics->{$structure}->{$mutationKey1}->{$mutationKey2} );
					} else { #mutationKey1 is same as mutationKey2
						if ( $this->{'vertex_type'} eq $WEIGHT ) { 
							$C += $weight;
						} else {
							if ( $refAlt1 ne $refAlt2 ) {
								$C += $weight;
							} else {
								$C += $weight - 1;
							}
						}
					}
					$centrality->{$superClusterID}->{$subClusterID}->{$mutationKey1} = $C;
					if ( $C > $max ) {
						$max = $C;
						$centroid = $mutationKey1;
					}
					#print join( "\t" , ( "cid=".$superClusterID.".".$subClusterID , "cent=".$centroid , "maxCc=".$max , "Cc=".$C ) )."\n";
				} #foreach refAlt2
			} #foreach mutationKey2
		} #foreach refAlt1
	} #foreach mutationKey1
	print join( "\t" , ( "result from calculation: " , $centroid , $max ) )."\n";
	return ( $centroid , $centrality );
}

#sub determineCentroid {
#	my ( $this , $centrality , $superClusterID ) = @_;
#	my $max = 0;
#	my $centroid = "";
#	foreach my $mutationKey ( keys %{$centrality->{$superClusterID}} ) {
#		my $C = $centrality->{$superClusterID}->{$mutationKey};
#		if ( $C > $max ) {
#			$max = $C;
#			$centroid = $mutationKey1;
#		}
#	}
#	return ( $centroid , $max );
#}

sub checkProcessedDistances {
	my ( $this , $distance_matrix , $structure ) = @_;
	my $count = 0;
	print "CHECK PROCESSED: \n";
	foreach my $mutationKey1 ( keys %{$distance_matrix->{$structure}} ) {
		print "\t".$mutationKey1;
		if ( not $this->hasBeenProcessed( $mutationKey1 ) ) {
			print "no\n";
			$count += 1;
		} else {
			print "yes\n";
		}
	}
	return $count;
}

sub anyFiniteGeodesicsRemaining {
	my ( $this , $mutations , $geodesics , $structure ) = @_;
	foreach my $mutationKey1 ( keys %{$geodesics->{$structure}} ) {
		next if ( $this->hasBeenProcessed( $mutationKey1 ) );
		foreach my $mutationKey2 ( keys %{$geodesics->{$structure}->{$mutationKey1}} ) {
			next if ( $this->hasBeenProcessed( $mutationKey2 ) 
				and $this->isRadiusOkay( $geodesics , $structure , $mutationKey1 , $mutationKey2 ) );
			return 1;
		}
	}
	return 0;
}

sub determineStructureClusters {
	my ( $this , $clusterings , $mutations , $distance_matrix ,
		 $fh , $structure , $superClusterID , $subClusterID ) = @_;
	print $structure."\t".$superClusterID.".".$subClusterID."\n";
	my $geodesics = $this->initializeGeodesics( $clusterings , $superClusterID ,
							$structure , $distance_matrix , $mutations );
	if ( $this->anyFiniteGeodesicsRemaining( $mutations , $geodesics , $structure ) ) {
		$this->floydWarshall( $geodesics , $structure );
		my ( $centroid , $centrality ) = $this->calculateClosenessCentrality( 
												$mutations , $geodesics , 
												$structure , $superClusterID , 
												$subClusterID );
		#$this->carveOutSubCluster( $mutations , $geodesics , $structure ,
		#		$centrality , $superClusterID , $subClusterID );
		$this->writeCluster( $fh , $mutations , $geodesics , $structure , 
				$superClusterID , $subClusterID , $centroid , $centrality );
		
		my $count = $this->checkProcessedDistances( $geodesics , $structure );
		print join( "\t" , ( "recluster?" , $count , 
				$superClusterID.".".$subClusterID , $structure ) );
		if ( $count >= 2 ) {
			$subClusterID += 1;
			print " yes\n";
			$this->determineStructureClusters( $clusterings , 
						$mutations , $geodesics , $fh , $structure , 
						$superClusterID , $subClusterID );
		} else {
			print " no\n";
			return 0;
		}
	#	my $numstructures = scalar keys %{$distance_matrix->{$structure}};
	#	if ( $this->{'structure_dependence'} eq $DEPENDENT ) {
	#		print STDOUT "Found ".$numclusters." super-clusters on ".$numstructures." structures\n";
	#	} else {
	#		print STDOUT "Found ".$numclusters." super-clusters\n";
	#	}
	} 
	return 1;
}

#TODO use this method to recalculate closeness centralities of acceptable region 
#		or else closeness centralities must be described as measured for the remaining
#		super cluster nodes within range
sub carveOutSubCluster {
	my ( $this , $mutations , $geodesics , $structure , $centroid ,
			$centrality , $superClusterID , $subClusterID ) = @_;
	#	$this->carveOutSubCluster( $mutations , $geodesics , $structure , $centroid ,
	#			$centrality , $superClusterID , $subClusterID );
	my $geods = {};
	foreach my $mutationKey ( keys %{$geodesics->{$structure}->{$centroid}} ) {
		$geods->{$structure}->{$centroid}->{$mutationKey} = $geodesics->{$structure}->{$centroid}->{$mutationKey};
	}
}

sub setProcessStatus {
	my ( $this , $mutationKey , $status ) = @_;
	$this->{'processed'}->{$mutationKey} = $status;
	return $this->{'processed'}->{$mutationKey};
}

sub hasBeenProcessed {
	my ( $this , $mutationKey ) = @_;
	if ( $this->{'processed'}->{$mutationKey} ) {
		return 1;
	}
	return 0;
}

sub writeCluster {
	#$this->writeCluster( $fh , $mutations , $geodesics , $structure , 
	#		$superClusterID , $subClusterID , $centroid , $centrality );
	my ( $this , $fh , $mutations , $geodesics , $structure ,
		 $superClusterID , $subClusterID , $centroid , $centrality ) = @_;
	print "writeCluster (".$subClusterID.") : ";
	my $clusterID = $superClusterID;
	if ( $this->{'structure_dependence'} eq $DEPENDENT 
		 or $this->{'subunit_dependence'} eq $DEPENDENT ) {
		$clusterID = join( "." , ( $superClusterID , $subClusterID , $structure ) );
	} else {
		$clusterID = join( "." , ( $superClusterID , $subClusterID ) );
	}
	my $geodesic = 0;
	my $degrees = scalar keys %{$geodesics->{$structure}->{$centroid}}; #TODO update to only count subcluster nodes
	my $closenessCentrality = $centrality->{$superClusterID}->{$subClusterID}->{$centroid};
	my ( $gene , $chromosome , $start , $stop ) = @{$this->splitMutationKey( $centroid )};
	my @alternateAnnotations;
	my $proteinChanges = {};
	my ( $reportedTranscript , $reportedAAChange );
	my $weight; # = $weights->{$proteinKey};
	foreach my $refAlt ( sort keys %{$mutations->{$centroid}} ) {
#TODO make sure this works for in_frame_ins
		my ( $reference , $alternate ) = @{&uncombine( $refAlt )};
		@alternateAnnotations = sort keys %{$mutations->{$centroid}->{$refAlt}};
		#print join( "," , ( @alternateAnnotations ) )."\n";
		my $reported = shift @alternateAnnotations;
		#print "\t".$reported."\n";
		$weight = $mutations->{$centroid}->{$refAlt}->{$reported};
		( $reportedTranscript , $reportedAAChange ) = @{$this->splitProteinKey( $reported )};
		my $alternateAnnotations = join( "|" , @alternateAnnotations );
		$fh->print( join( "\t" , ( $clusterID , $gene , $reportedAAChange , 
								   $degrees , $closenessCentrality , 
								   $geodesic , $weight ,
								   $chromosome , $start , $stop ,
								   $reference , $alternate ,
								   $reportedTranscript , $alternateAnnotations
								 )
						)."\n"
				  );
	} #foreach refAlt
	$this->setProcessStatus( $centroid , 1 );
	foreach my $mutationKey2 ( sort keys %{$geodesics->{$structure}->{$centroid}} ) {
		next if ( $this->hasBeenProcessed( $mutationKey2 ) );
		$geodesic = $geodesics->{$structure}->{$centroid}->{$mutationKey2};
		next if ( $geodesic > $this->{'max_radius'} ); 
		print $centroid." geodesic to ".$mutationKey2."\t".$geodesic."\n";
		$degrees = scalar keys %{$geodesics->{$structure}->{$mutationKey2}}; #TODO update to only count subcluster nodes
		$closenessCentrality = $centrality->{$superClusterID}->{$subClusterID}->{$mutationKey2};
		( $gene , $chromosome , $start , $stop ) = @{$this->splitMutationKey( $mutationKey2 )};
		@alternateAnnotations;
		$proteinChanges = {};
		( $reportedTranscript , $reportedAAChange );
		$weight; # = $weights->{$proteinKey};
		foreach my $refAlt ( sort keys %{$mutations->{$mutationKey2}} ) {
#TODO make sure this works for in_frame_ins
			my ( $reference , $alternate ) = @{&uncombine( $refAlt )};
			@alternateAnnotations = sort keys %{$mutations->{$mutationKey2}->{$refAlt}};
			#print join( "," , ( @alternateAnnotations ) )."\n";
			my $reported = shift @alternateAnnotations;
			#print "\t".$reported."\n";
			$weight = $mutations->{$mutationKey2}->{$refAlt}->{$reported};
			( $reportedTranscript , $reportedAAChange ) = @{$this->splitProteinKey( $reported )};
			my $alternateAnnotations = join( "|" , @alternateAnnotations );
			$fh->print( join( "\t" , ( $clusterID , $gene , $reportedAAChange , 
									   $degrees , $closenessCentrality , 
									   $geodesic , $weight ,
									   $chromosome , $start , $stop ,
									   $reference , $alternate ,
									   $reportedTranscript , $alternateAnnotations
									 )
							)."\n"
					  );
		} #foreach refAlt
		print "deleting: ".$mutationKey2." and distances with centroid ".$centroid."\n";
		$this->setProcessStatus( $mutationKey2 , 1 );
	} #foreach other vertex in network
	return;
}

sub floydWarshall {
	my ( $this , $geodesics , $structure ) = @_;
	print "floydWarshall: \n";
	foreach my $mu_k ( keys %{$geodesics->{$structure}} ) {
		#print "\t".$mu_k."\n";
		foreach my $mu_i ( keys %{$geodesics->{$structure}} ) {
			#print "\t\t".$mu_i."\n";
			my ( $dist_ik , $dist_ij , $dist_kj );
			if ( exists $geodesics->{$structure}->{$mu_i}->{$mu_k} ) {
				$dist_ik = $geodesics->{$structure}->{$mu_i}->{$mu_k};
			} else {
				$dist_ik = $MAXDISTANCE;
			}
			foreach my $mu_j ( keys %{$geodesics->{$structure}} ) {
				if ( exists $geodesics->{$structure}->{$mu_i}->{$mu_j} ) {
					$dist_ij = $geodesics->{$structure}->{$mu_i}->{$mu_j};
				} else {
					$dist_ij = $MAXDISTANCE;
				}
				next if ( $dist_ij == 0 );
				if ( exists $geodesics->{$structure}->{$mu_k}->{$mu_j} ) {
					$dist_kj = $geodesics->{$structure}->{$mu_k}->{$mu_j};
				} else {
					$dist_kj = $MAXDISTANCE;
				}
				if ( $dist_ij > $dist_ik + $dist_kj ) {
					$geodesics->{$structure}->{$mu_i}->{$mu_j} = $dist_ik + $dist_kj;
					$geodesics->{$structure}->{$mu_j}->{$mu_i} = $dist_ik + $dist_kj;
#					print join( " -- " , ( $mu_i , $mu_j , 
#							$dist_ij , $dist_ik , $dist_kj , 
#							$geodesics->{$structure}->{$mu_i}->{$mu_j} 
#							) )."\n";
				}
			}
		}
	}
	return;
}

## MUTATIONS
sub isSameProteinPosition {
	my ( $this , $mutations , $mutationKey1 , $mutationKey2 ) = @_;
	print join( "\t" , ( "begin" , $mutationKey1 , $mutationKey2 ) )."\n";
	if ( $mutationKey1 eq $mutationKey2 ) { return 1; }
	my ( undef , $chromosome1 , $start1 , undef ) = @{$this->splitMutationKey( $mutationKey1 )};
	next if ( !$start1 );
	my ( undef , $chromosome2 , $start2 , undef ) = @{$this->splitMutationKey( $mutationKey2 )};
	next if ( !$start2 );
	my $diff = 3;
	if ( $start1 <= $start2 ) {
		$diff = $start2 - $start1;
	} else {
		$diff = $start1 - $start2;
	}
	#print "\tdiff = ".$diff."\n";
	foreach my $refAlt1 ( sort keys %{$mutations->{$mutationKey1}} ) {
		foreach my $proteinKey1 ( sort keys %{$mutations->{$mutationKey1}->{$refAlt1}} ) {
			my ( $transcript1 , $aaChange1 ) = @{$this->splitProteinKey( $proteinKey1 )};
			my ( $aaReference1 , $aaPosition1 , $aaAlternate1 );
			#print "\tproteinKey1: ".$proteinKey1;
			if ( $aaChange1 =~ m/p\.\D\D*(\d+)\D*/ ) {
				$aaPosition1 =  $1;
			} else {
				print "...next, no match aaChange1\n";
				next;
			}
			foreach my $refAlt2 ( sort keys %{$mutations->{$mutationKey2}} ) {
#TODO make sure this works for in_frame_ins
				foreach my $proteinKey2 ( sort keys %{$mutations->{$mutationKey2}->{$refAlt2}} ) {
					my ( $transcript2 , $aaChange2 ) = @{$this->splitProteinKey( $proteinKey2 )};
					my ( $aaReference2 , $aaPosition2 , $aaAlternate2 );
					#print "\tproteinKey2: ".$proteinKey2."\t";
					if ( $aaChange2 =~ m/p\.\D\D*(\d+)\D*/ ) {
						$aaPosition2 =  $1;
					} else {
						print "...next, no match aaChange2\n";
						next;
					}
					#print join( "\t" , ( $aaPosition1 , $aaReference1 , $aaPosition2 , $aaReference2 ) )."\t";
					if ( $transcript1 eq $transcript2 and $aaPosition1 eq $aaPosition2 ) {
						print "<--same aaPosition\n";
						return 1;
					}
#TODO may fail at splice sites
					if ( $chromosome1 eq $chromosome2 
						 and $diff <= 2 ) {
#TODO make sure that the transcript details assure this works
						print "<--same protein ref/alt ".$start2." - ".$start1." = ".$diff."\n";
						return 1;
					}
				} #foreach proteinKey2
			} #foreach refAlt2
			#print "\n";
		} #foreach proteinKey1
	} #foreach refAlt1
	return 0;
}

sub makeMutationKey {
	my ( $this , $mutation ) = @_;
	#my $proteinMutation = $mutation->proteinVariant( 0 );
	#my $mutationKey = &combine( $mutation->gene() , $proteinMutation->transcript() );
	#$mutationKey = &combine( $mutationKey , $proteinMutation->aminoAcidChange() );
	#$mutationKey = &combine( $mutationKey , $mutation->chromosome() );
	my $mutationKey = &combine( $mutation->gene() , $mutation->chromosome() );
	$mutationKey = &combine( $mutationKey , $mutation->start() );
	$mutationKey = &combine( $mutationKey , $mutation->stop() );
	#if ( $mutation->reference() ) {
	#	if ( $mutation->alternate() ) {
	#		$mutationKey = &combine( $mutationKey , $mutation->reference() );
	#		$mutationKey = &combine( $mutationKey , $mutation->alternate() );
	#	}
	#}
	return $mutationKey;
}

sub makeRefAltKey {
	my ( $this , $mutation ) = @_;
	return &combine( $mutation->reference() , $mutation->alternate() );
}

sub makePairKey {
	my ( $this , $mutation1 , $mutation2 ) = @_;
	my $mutationKey1 = $this->makeMutationKey( $mutation1 );
	my $mutationKey2 = $this->makeMutationKey( $mutation2 );
	return $mutationKey1."_".$mutationKey2;
}

sub makeProteinKey {
	my ( $this , $mutation ) = @_;
	#print "makeProteinKey: ";
	#print $this->makeMutationKey( $mutation ).": ";
	my $proteinVariant = $mutation->proteinVariant();
	my $proteinKey = &combine( $proteinVariant->transcript() , $proteinVariant->aminoAcidChange() );
	#print $proteinKey."\n";
	return $proteinKey;
}

sub splitMutationKey {
	my ( $this , $mutationKey ) = @_;
	return &uncombine( $mutationKey );
}

sub splitRefAltKey {
	my ( $this , $refAlt ) = @_;
	return &uncombine( $refAlt );
}

sub splitPairKey {
	my ( $this , $pairKey ) = @_;
	return (split /_/ , $pairKey);
}

sub splitProteinKey {
	my ( $this , $proteinKey ) = @_;
	my @split = @{&uncombine( $proteinKey )};
	return \@split;
}

sub getPairKeys {
	my ( $this , $mutation1 , $mutation2 ) = @_;
	my $pairKeyA = $this->makePairKey( $mutation1 , $mutation2 );
	my $pairKeyB = $this->makePairKey( $mutation2 , $mutation1 );
	return ( $pairKeyA , $pairKeyB );
}

## DISTANCE MATRIX
sub checkPair {
	my ( $this , $dist , $pval ) = @_;
	if ( $this->{'3d_distance_cutoff'} == $MAXDISTANCE ) { #3d-dist undef & p-val def
		if ( $pval < $this->{'p_value_cutoff'} ) {
			return 1;
		}
	} elsif ( $this->{'p_value_cutoff'} == 1 ) { #3d-dist def & p-val undef
		if ( $dist < $this->{'3d_distance_cutoff'} ) {
			return 1;
		}
	} else { #3d-dist def & p-val def
		if ( $dist < $this->{'3d_distance_cutoff'} and $pval < $this->{'p_value_cutoff'} ) {
			return 1;
		}
	}
	return 0;
}

sub setShortestDistance {
	my ( $this , $distance_matrix , $mutation1 , $mutation2 , $chain1 , $chain2 , $infos ) = @_;
	my @infos = split /\|/ , $infos;
	my $nStructures = scalar @infos;
	if ( $this->{'structure_dependence'} eq $DEPENDENT ) {
		foreach my $info ( @infos ) {
			chomp( $info );
			my ( $distance , $pdbID , $pvalue ) = split / / , $infos;
#TODO corresponding to update in setAverageDistance
			if ( $this->checkPair( $distance , $pvalue ) ) {
				$this->setElement( $distance_matrix , $pdbID , $mutation1 , $mutation2 , $distance , $pvalue );
			}
		}
	} else {
		my ( $distance , $pdbID , $pvalue ) = split / / , $infos[0];
#TODO corresponding to update in setAverageDistance
		if ( $this->checkPair( $distance , $pvalue ) ) {
			$this->setElement( $distance_matrix , $ANY , $mutation1 , $mutation2 , $distance , $pvalue );
		}
	}
	return;
}

#TODO make sure set for average works as well as for shortest
sub setAverageDistance {
	my ( $this , $distance_matrix , $mutation1 , $mutation2 , $chain1 , $chain2 , $infos , $pdbCount ) = @_;
	my @infos = split /\|/ , $infos;
	my $sumDistances = {};
	my $nStructures = {};
	foreach my $info ( @infos ) {
		chomp( $info );
		next unless ( $info );
		my ( $distance , $pdbID , $pvalue ) = split / / , $info;
#TODO average over ALL pairs or just the ones satisfying conditions (leave checkPair here if latter)
		if ( $this->checkPair( $distance , $pvalue ) ) {
			my $structure = $this->structureDependent( $pdbID , $chain1 , $chain2 );
			$sumDistances->{$structure} += $distance;
			$nStructures->{$structure} += 1;
		}
	}
	$this->calculateAverageDistance( $distance_matrix , $mutation1 , $mutation2 , $pdbCount , $sumDistances , $nStructures );
	return;
}

sub calculateAverageDistance {
	my ( $this , $distance_matrix , $mutation1 , $mutation2 , $pdbCount , $sumDistances , $nStructures ) = @_;
	my $mutationKey1 = $this->makeMutationKey( $mutation1 );
	my $mutationKey2 = $this->makeMutationKey( $mutation2 );
	foreach my $structure ( keys %{$sumDistances} ) {
		if ( exists $pdbCount->{$structure}->{$mutationKey1} ) {
			if ( exists $pdbCount->{$structure}->{$mutationKey1}->{$mutationKey2} ) { #have seen the pair on a prior line
				my $count = $pdbCount->{$structure}->{$mutationKey1}->{$mutationKey2};
				my $oldDistance = $this->getElement( $distance_matrix , $structure , $mutation1 , $mutation2 );
				$sumDistances->{$structure} += $count*$oldDistance;
				$nStructures->{$structure} += $count;
			} else {
				$pdbCount->{$structure}->{$mutationKey1}->{$mutationKey2} = $nStructures;
			}
		} else {
			$pdbCount->{$structure}->{$mutationKey1}->{$mutationKey2} = $nStructures;
		}
		my $finalDistance = $sumDistances->{$structure} / $nStructures->{$structure};
		$this->setElement( $distance_matrix , $structure , $mutation1 , $mutation2 , $finalDistance );
	}
	return;
}

sub setDistance {
	my ( $this , $distance_matrix , $mutation1 , $mutation2 , 
		 $chain1 , $chain2 , $infos , $pdbCount ) = @_;
	if ( $this->{'distance_measure'} eq $AVERAGEDISTANCE ) {
		#print "get average distance\n";
		$this->setAverageDistance( $distance_matrix , $mutation1 , $mutation2 , 
								   $chain1 , $chain2 , $infos , $pdbCount );
	} else {
		#print "get shortest distance\n";
		$this->setShortestDistance( $distance_matrix , $mutation1 , 
									$mutation2 , $chain1 , $chain2 , $infos );
	}
	return;
}

sub setElement {
	my ( $this , $distance_matrix , $structure , $mutation1 , $mutation2 , $distance ) = @_;
#TODO corresponding to update in setAverageDistance
	#if ( $this->checkPair( $distance , $pvalue ) ) { #meets desired significance
		my $mutationKey1 = $this->makeMutationKey( $mutation1 );
		my $mutationKey2 = $this->makeMutationKey( $mutation2 );
		if ( not exists $distance_matrix->{$structure}->{$mutationKey1} ) {
			if ( not exists $distance_matrix->{$structure}->{$mutationKey1}->{$mutationKey2} ) {
				$distance_matrix->{$structure}->{$mutationKey1}->{$mutationKey2} = $distance;
				$distance_matrix->{$structure}->{$mutationKey2}->{$mutationKey1} = $distance;
			}
		}
		$this->setProcessStatus( $mutationKey1 , 0 );
		$this->setProcessStatus( $mutationKey2 , 0 );
	#}
	return;
}

sub initializeSameSiteDistancesToZero {
	my ( $this , $distance_matrix , $mutations ) = @_;
	foreach my $structure ( keys %{$distance_matrix} ) {
		foreach my $mutationKey1 ( keys %{$distance_matrix->{$structure}} ) {
			foreach my $mutationKey2 ( keys %{$distance_matrix->{$structure}} ) {
#TODO if mutationKeys are equal, but protein change is different
				next if ( $mutationKey1 eq $mutationKey2 );
				if ( $this->isSameProteinPosition( $mutationKey1 , $mutationKey2 ) ) {
					$distance_matrix->{$structure}->{$mutationKey1}->{$mutationKey2} = 0;
					$distance_matrix->{$structure}->{$mutationKey2}->{$mutationKey1} = 0;
				}
			}
		}
	}
}

sub getElement {
	my ( $this , $distance_matrix , $structure , $mutation1 , $mutation2 ) = @_;
	my $mutationKey1 = $this->makeMutationKey( $mutation1 );
	my $mutationKey2 = $this->makeMutationKey( $mutation2 );
	return ( $this->getElementByKeys( $distance_matrix , $structure , $mutationKey1 , $mutationKey2 ) );
}

sub getElementByKeys {
	my ( $this , $distance_matrix , $structure , $mutationKey1 , $mutationKey2 ) = @_;
	my $distance = $MAXDISTANCE;
	if ( exists $distance_matrix->{$structure}->{$mutationKey1} ) {
		if ( exists $distance_matrix->{$structure}->{$mutationKey1}->{$mutationKey2} ) {
			$distance = $distance_matrix->{$structure}->{$mutationKey1}->{$mutationKey2};
		}
	} elsif ( exists $distance_matrix->{$structure}->{$mutationKey2} ) {
		print STDERR "ASYMMETRIC DISTANCE MATRIX\n";
		if ( exists $distance_matrix->{$structure}->{$mutationKey2}->{$mutationKey1} ) {
			$distance = $distance_matrix->{$structure}->{$mutationKey2}->{$mutationKey1};
		}
	}
	return $distance;
}

sub structureDependent {
	my ( $this , $structure , $chain1 , $chain2 ) = @_;
	$structure = $this->structureDependence( $structure , $chain1 , $chain2 );
	$structure = $this->subunitDependence( $structure , $chain1 , $chain2 );
	return $structure;
}

sub structureDependence {
	my ( $this , $structure , $chain1 , $chain2 ) = @_;
	if ( $this->{'structure_dependence'} eq $DEPENDENT ) {
		return $this->subunitDependence( $structure , $chain1 , $chain2 );
	} elsif ( $this->{'subunit_dependence'} eq $DEPENDENT ) {
		return $this->subunitDependence( $structure , $chain1 , $chain2 );
	}
	return $ANY;
}

sub subunitDependence {
	my ( $this , $structure , $chain1 , $chain2 ) = @_;
	if ( $this->{'subunit_dependence'} eq $DEPENDENT ) {
		return &combine( &combine( $structure , $chain1 ) , $chain2 );
	} elsif ( $this->{'structure_dependence'} eq $DEPENDENT ) {
		return $structure;
	}
	return $ANY;
}


## MISCELLANEOUS METHODS
sub numSort {
	my ( $list ) = @_;
	if ( scalar @{$list} > 0 ) {
		@{$list} = sort {$a <=> $b} @{$list};
	}
	return;
}

sub combine {
	my ( $a , $b ) = @_;
	return join( ":" , ( $a , $b ) );
}

sub uncombine {
	my $a = shift;
	my @split = split( /\:/ , $a );
	return \@split;
}

sub density_help_text{
    my $this = shift;
        return <<HELP

Usage: hotspot3d density [options]

                             REQUIRED
--pairwise-file              3D pairwise data file

                             OPTIONAL
--Epsilon                    Epsilon value, default: 10
--MinPts                     MinPts, default: 4
--number-of-runs             Number of density clustering runs to perform before the cluster membership probability being calculated, default: 10
--probability-cut-off        Clusters will be formed with variants having at least this probability, default: 100
--distance-measure           Pair distance to use (shortest or average), default: average
--structure-dependence       Clusters for each structure or across all structures (dependent or independent), default: independent 

--help                       this message

HELP
}

sub help_text {
    my $this = shift;
        return <<HELP

Usage: hotspot3d cluster [options]

                             REQUIRED
--pairwise-file              3D pairwise data file
--maf-file                   .maf file used in proximity search step

                             OPTIONAL
--drug-clean-file            Either (or concatenated) drugs.target.clean & drugs.nontarget.clean data
--output-prefix              Output prefix, default: 3D_Proximity
--p-value-cutoff             P_value cutoff (<), default: 0.05 (if 3d-distance-cutoff also not set)
--3d-distance-cutoff         3D distance cutoff (<), default: 100 (if p-value-cutoff also not set)
--linear-cutoff              Linear distance cutoff (> peptides), default: 0
--max-radius                 Maximum cluster radius (max network geodesic from centroid, <= Angstroms), default: 10
--clustering                 Cluster using network or density-based methods (network or density), default: network
--vertex-type                Graph vertex type for network-based clustering (recurrence, unique, or weight), default: recurrence
--distance-measure           Pair distance to use (shortest or average), default: average
--structure-dependence       Clusters for each structure or across all structures (dependent or independent), default: independent
--transcript-id-header       .maf file column header for transcript id's, default: transcript_name
--amino-acid-header          .maf file column header for amino acid changes, default: amino_acid_change 
--weight-header              .maf file column header for mutation weight, default: weight (used if vertex-type = weight)

--help                       this message

HELP

}

1;
