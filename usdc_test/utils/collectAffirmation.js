
const fs = require('fs')
const path = require('path')  
const filePath = path.join(__dirname, "..","test_output");

const USER_REQUEST_FOR_AFFIRMATION="0x482515ce3d9494a37ce83f18b72b363449458435fafdd7a53ddea7460fe01b58";
  
async function collectAffirmation() {
  
     fs.readFile(filePath + "/ETH_relayTokens.json", {encoding: 'utf-8'}, (err,data)=>{
        if(err) console.err(err);
        if(data){
            const output = JSON.parse(data)
            output["usdc_test/eth.t.sol:ethTest"]["test_results"]["test_relayTokensFromETH()"]["logs"].forEach((log)=>{
                if(log.topics[0]==USER_REQUEST_FOR_AFFIRMATION)
                    {
                        console.log("Found User Request for Affirmation event")
                        if(log.data.substring(0,6)!="0x0005")
                            log.data = "0x"+log.data.substring(130);
                            fs.writeFile(filePath+"/GNO_input.json",JSON.stringify(log),()=>{});
                        }
          
        });
        }
    });
   
}

collectAffirmation()