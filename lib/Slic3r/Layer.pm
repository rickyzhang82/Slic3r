package Slic3r::Layer;
use Moo;

use List::Util qw(first);
use Slic3r::Geometry qw(scale);
use Slic3r::Geometry::Clipper qw(union_ex);

has 'id'                => (is => 'rw', required => 1, trigger => 1); # sequential number of layer, 0-based
has 'object'            => (is => 'ro', weak_ref => 1, required => 1);
has 'regions'           => (is => 'ro', default => sub { [] });
has 'slicing_errors'    => (is => 'rw');

has 'slice_z'           => (is => 'lazy');
has 'print_z'           => (is => 'lazy');
has 'height'            => (is => 'lazy');
has 'flow'              => (is => 'lazy');

# collection of expolygons generated by slicing the original geometry;
# also known as 'islands' (all regions are merged here)
has 'slices'            => (is => 'rw');

# ordered collection of extrusion paths to fill surfaces for support material
has 'support_islands'           => (is => 'rw');
has 'support_fills'             => (is => 'rw');
has 'support_contact_fills'     => (is => 'rw');

sub _trigger_id {
    my $self = shift;
    $_->_trigger_layer for @{$self->regions || []};
}

# Z used for slicing in scaled coordinates
sub _build_slice_z {
    my $self = shift;
    
    if ($Slic3r::Config->raft_layers == 0) {
        if ($self->id == 0) {
            return scale $Slic3r::Config->get_value('first_layer_height') / 2;
        }
        return scale($Slic3r::Config->get_value('first_layer_height') + ($self->id-1 + 0.5) * $Slic3r::Config->layer_height);
    } else {
        return -1 if $self->id < $Slic3r::Config->raft_layers;
        my $object_layer_id = $self->id - $Slic3r::Config->raft_layers;
        return scale ($object_layer_id + 0.5) * $Slic3r::Config->layer_height;
    }
}

# Z used for printing in scaled coordinates
sub _build_print_z {
    my $self = shift;
    return ($Slic3r::Config->get_value('first_layer_height') + ($self->id * $Slic3r::Config->layer_height)) / &Slic3r::SCALING_FACTOR;
}

# layer height in unscaled coordinates
sub _build_height {
    my $self = shift;
    return $self->id == 0 ? $Slic3r::Config->get_value('first_layer_height') : $Slic3r::Config->layer_height;
}

sub _build_flow { $Slic3r::flow }

# layer height of contact paths in unscaled coordinates
sub support_material_contact_height {
    my $self = shift;
    
    return $self->height if $self->id == 0;
    
    # this is not very correct because:
    # - we should sum our height with the actual upper layers height (which might be different)
    # - we should use the actual flow of the upper layer bridges, not the default one
    # ...but we're close enough for now
    return 2*$self->height - $self->flow->nozzle_diameter;
}

# Z used for printing support material contact in scaled coordinates
sub support_material_contact_z {
    my $self = shift;
    return $self->print_z - ($self->height - $self->support_material_contact_height) / &Slic3r::SCALING_FACTOR;
}

sub region {
    my $self = shift;
    my ($region_id) = @_;
    
    for (my $i = @{$self->regions}; $i <= $region_id; $i++) {
        $self->regions->[$i] //= Slic3r::Layer::Region->new(
            layer   => $self,
            region  => $self->object->print->regions->[$i],
        );
    }
    
    return $self->regions->[$region_id];
}

# merge all regions' slices to get islands
sub make_slices {
    my $self = shift;
    
    # optimization for single-region layers
    my @regions_with_slices = grep { @{$_->slices} } @{$self->regions};
    if (@regions_with_slices == 1) {
        $self->slices([ map $_->expolygon, @{$regions_with_slices[0]->slices} ]);
        return;
    }
    
    $self->slices(union_ex([ map $_->p, map @{$_->slices}, @{$self->regions} ]));
}

sub make_perimeters {
    my $self = shift;
    Slic3r::debugf "Making perimeters for layer %d\n", $self->id;
    $_->make_perimeters for @{$self->regions};
}

sub support_islands_enclose_line {
    my $self = shift;
    my ($line) = @_;
    return (first { $_->encloses_line($line) } @{$self->support_islands}) ? 1 : 0;
}

1;
