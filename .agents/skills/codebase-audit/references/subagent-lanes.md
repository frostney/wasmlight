## Sub-agent lanes

When the user supplies `subagents`, the coordinating agent still owns the audit
scope, coverage map, capability map, active and skipped perspectives, validation,
final findings, remediation batches, and report.

1. Publish a bounded lane map before delegation. Form lanes from capability and
   perspective intersections so no worker receives an unbounded whole-repository
   perspective. Give each lane one worker; tightly coupled or individually small
   perspectives may share a lane. Queue excess lanes when platform capacity is
   temporarily full.
2. Give each worker its lane ID, assigned capability and perspectives, bounded
   scope, relevant project instructions, and known evidence. A worker may inspect
   and run the safe probes allowed by this skill, but it must not edit, create
   persistent or external side effects, delegate further, assign final finding
   IDs or severities, propose final remediation batches, or issue an overall
   conclusion.
3. Require each worker to return its lane ID, assigned capability and
   perspectives, bounded scope, inspected supporting context, exact probes and
   observed results, candidate findings with evidence, impact, and smallest
   remedy, verified claims, limitations, and `complete` or `incomplete` status.
4. Validate every candidate against the current checkout, apply the
   de-duplication model below, reconcile conflicts across lanes, then assign
   final IDs, severities, categories, remediation batches, and conclusions. Do
   not repeat a completed lane wholesale.
5. If sub-agents are unsupported, unavailable after any applicable bounded
   retry, or leave a lane incomplete, complete that lane directly. Report the
   affected lane and reason as a single-agent fallback. Temporary capacity
   exhaustion queues work rather than triggering immediate fallback.

Before starting a worker, identify its actual model from host metadata. Deliver
the applicable role, scope, authority, completion condition, and required skill
contents or reachable reference paths; naming a skill is not proof of delivery.
Record the resources the worker actually loaded and any missing capability in
its result. An isolated worker must not assume parent conversation or loaded
skills are inherited. Keep model-specific settings at the host boundary and
apply them only to the actual worker when supported by evidence.
