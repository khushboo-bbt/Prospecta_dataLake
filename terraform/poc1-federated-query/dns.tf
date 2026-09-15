# Private hosted zone for the sandbox VPC, so Redshift's federated-query
# resolver can reliably resolve the PgBouncer NLB. Confirmed via testing:
# the raw ELB-assigned hostname (*.elb.ap-southeast-1.amazonaws.com) resolves
# fine from a normal EC2 instance in this VPC, but Redshift Serverless's
# federated-query connector fails with "curlCode: 6, Couldn't resolve host
# name" against that same hostname even with enhanced_vpc_routing enabled —
# a custom name under a private hosted zone associated with the VPC is the
# standard fix for this class of issue.
resource "aws_route53_zone" "poc1_internal" {
  name = "${var.name_prefix}.internal"

  vpc {
    vpc_id = var.vpc_id
  }

  tags = var.tags
}

resource "aws_route53_record" "pgbouncer" {
  zone_id = aws_route53_zone.poc1_internal.zone_id
  name    = "pgbouncer.${aws_route53_zone.poc1_internal.name}"
  type    = "A"

  alias {
    name                   = aws_lb.pgbouncer.dns_name
    zone_id                = aws_lb.pgbouncer.zone_id
    evaluate_target_health = true
  }
}
