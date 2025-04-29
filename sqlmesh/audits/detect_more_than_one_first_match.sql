AUDIT (
  name detect_more_than_one_first_match,
  blocking TRUE
);

SELECT contact_id
, lead_id
, COUNT(*) AS active_count
FROM @this_model
WHERE valid_to is null and contact_lead_first_match
GROUP BY contact_id, lead_id
HAVING COUNT(*) > 1

