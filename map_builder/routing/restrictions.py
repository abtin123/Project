from abm_builder.core import entity_id, tags_dict

def extract_restrictions(relations):
    result=[]
    for rel in relations:
        tags=tags_dict(rel)
        kind=tags.get('restriction','')
        if tags.get('type') == 'restriction' or kind.startswith(('no_', 'only_')):
            result.append({'id':entity_id(rel),'restriction':kind,'from':tags.get('from',''),'via':tags.get('via',''),'to':tags.get('to','')})
    return result
