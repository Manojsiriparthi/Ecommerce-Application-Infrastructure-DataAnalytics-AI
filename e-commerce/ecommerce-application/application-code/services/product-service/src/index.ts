import 'dotenv/config'; import express from 'express'; import cors from 'cors'; import helmet from 'helmet'; import {PrismaClient} from '@prisma/client';
const app=express(),prisma=new PrismaClient(),port=Number(process.env.PORT||4002);app.use(helmet());app.use(cors());app.use(express.json());
app.get('/health',(_,r)=>r.json({service:'product-service',status:'ok'}));
app.get('/api/products',async(req,res)=>{const {gender,category,search}=req.query;const products=await prisma.product.findMany({where:{...(gender&&{gender:String(gender)}),...(category&&{category:String(category)}),...(search&&{OR:[{name:{contains:String(search),mode:'insensitive'}},{description:{contains:String(search),mode:'insensitive'}}]})},orderBy:{createdAt:'desc'}});res.json({products})});
app.get('/api/products/:id',async(req,res)=>{const p=await prisma.product.findUnique({where:{id:req.params.id}});return p?res.json({product:p}):res.status(404).json({message:'Product not found'})});
app.post('/api/products',async(req,res)=>{const {name,description,category,gender,price,stock,imageUrl}=req.body;if(!name||!category||!gender||price===undefined)return res.status(400).json({message:'Required product fields missing'});const p=await prisma.product.create({data:{name,description:description||'',category,gender,price,stock:Number(stock||0),imageUrl}});res.status(201).json({product:p})});
app.patch('/api/products/:id',async(req,res)=>{const p=await prisma.product.update({where:{id:req.params.id},data:req.body});res.json({product:p})});
app.listen(port,()=>console.log(`product-service listening on ${port}`));
